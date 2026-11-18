-- ChessArena player intelligence migration.
-- Safe to rerun. All rated updates use row locks and a single game completion state.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS rating INTEGER DEFAULT 200,
  ADD COLUMN IF NOT EXISTS country TEXT,
  ADD COLUMN IF NOT EXISTS biography TEXT,
  ADD COLUMN IF NOT EXISTS online_status TEXT NOT NULL DEFAULT 'offline';

ALTER TABLE public.games
  ADD COLUMN IF NOT EXISTS rated BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS format TEXT;

UPDATE public.games
SET format = CASE
  WHEN time_control IN ('1+0') THEN 'bullet'
  WHEN time_control IN ('3+0', '3+2', '5+0') THEN 'blitz'
  WHEN time_control IN ('10+0', '10+5') THEN 'rapid'
  ELSE 'classical'
END
WHERE format IS NULL;

CREATE TABLE IF NOT EXISTS public.player_ratings (
  profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  format TEXT NOT NULL CHECK (format IN ('bullet', 'blitz', 'rapid', 'classical')),
  rating INTEGER NOT NULL DEFAULT 200 CHECK (rating >= 0),
  highest_rating INTEGER NOT NULL DEFAULT 200,
  lowest_rating INTEGER NOT NULL DEFAULT 200,
  games_played INTEGER NOT NULL DEFAULT 0,
  wins INTEGER NOT NULL DEFAULT 0,
  losses INTEGER NOT NULL DEFAULT 0,
  draws INTEGER NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (profile_id, format)
);

CREATE TABLE IF NOT EXISTS public.rating_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  game_id UUID NOT NULL REFERENCES public.games(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  format TEXT NOT NULL CHECK (format IN ('bullet', 'blitz', 'rapid', 'classical')),
  previous_rating INTEGER NOT NULL,
  new_rating INTEGER NOT NULL,
  rating_change INTEGER NOT NULL,
  result TEXT NOT NULL,
  played_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (game_id, profile_id)
);

CREATE TABLE IF NOT EXISTS public.achievements (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  icon TEXT
);

CREATE TABLE IF NOT EXISTS public.player_achievements (
  profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  achievement_id TEXT NOT NULL REFERENCES public.achievements(id) ON DELETE CASCADE,
  unlocked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  progress INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (profile_id, achievement_id)
);

CREATE TABLE IF NOT EXISTS public.opening_statistics (
  profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  opening_name TEXT NOT NULL,
  color TEXT NOT NULL CHECK (color IN ('white', 'black')),
  games_played INTEGER NOT NULL DEFAULT 0,
  wins INTEGER NOT NULL DEFAULT 0,
  losses INTEGER NOT NULL DEFAULT 0,
  draws INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (profile_id, opening_name, color)
);

INSERT INTO public.player_ratings (profile_id, format)
SELECT p.id, format
FROM public.profiles p
CROSS JOIN (VALUES ('bullet'), ('blitz'), ('rapid'), ('classical')) formats(format)
ON CONFLICT (profile_id, format) DO NOTHING;

INSERT INTO public.achievements (id, name, description, icon) VALUES
  ('first_victory', 'First Victory', 'Win your first rated game.', 'trophy'),
  ('rating_250', 'Rating 250', 'Reach 250 ChessArena Rating points.', 'medal'),
  ('rating_500', 'Rating 500', 'Reach 500 ChessArena Rating points.', 'medal'),
  ('rating_1000', 'Rating 1000', 'Reach 1000 ChessArena Rating points.', 'crown'),
  ('win_streak_5', 'Win Streak', 'Win 5 rated games in a row.', 'flame')
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  icon = EXCLUDED.icon;

CREATE INDEX IF NOT EXISTS idx_rating_history_profile_played
  ON public.rating_history(profile_id, played_at DESC);
CREATE INDEX IF NOT EXISTS idx_rating_history_format
  ON public.rating_history(format, played_at DESC);
CREATE INDEX IF NOT EXISTS idx_player_ratings_format_rating
  ON public.player_ratings(format, rating DESC);

CREATE OR REPLACE FUNCTION public.apply_online_game_action(
  p_game_id UUID,
  p_actor_id UUID,
  p_expected_fen TEXT,
  p_action TEXT,
  p_next_fen TEXT DEFAULT NULL,
  p_moves JSONB DEFAULT NULL,
  p_pgn TEXT DEFAULT NULL,
  p_result TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  selected_game public.games%ROWTYPE;
  white_previous INTEGER;
  black_previous INTEGER;
  white_change INTEGER;
  black_change INTEGER;
  rating_format TEXT;
BEGIN
  IF p_actor_id IS NULL OR p_expected_fen IS NULL THEN
    RAISE EXCEPTION 'Missing game action identity or state' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO selected_game
  FROM public.games
  WHERE id = p_game_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Game not found' USING ERRCODE = 'P0002';
  END IF;
  IF selected_game.white_player_id IS NULL OR selected_game.black_player_id IS NULL
    OR (p_actor_id IS DISTINCT FROM selected_game.white_player_id
      AND p_actor_id IS DISTINCT FROM selected_game.black_player_id) THEN
    RAISE EXCEPTION 'You are not a participant in this game' USING ERRCODE = '42501';
  END IF;
  IF selected_game.status <> 'in_progress' OR selected_game.result <> 'in_progress' THEN
    RAISE EXCEPTION 'Game is not in progress' USING ERRCODE = '40001';
  END IF;
  IF selected_game.fen IS DISTINCT FROM p_expected_fen THEN
    RAISE EXCEPTION 'Game changed; refresh before retrying' USING ERRCODE = '40001';
  END IF;

  IF p_action = 'move' THEN
    IF p_next_fen IS NULL OR BTRIM(p_next_fen) = ''
      OR p_moves IS NULL OR jsonb_typeof(p_moves) <> 'array'
      OR p_pgn IS NULL OR p_result IS NULL
      OR p_result NOT IN ('in_progress', 'white_wins', 'black_wins', 'draw') THEN
      RAISE EXCEPTION 'Invalid move state' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_moves) submitted_move
      WHERE jsonb_typeof(submitted_move.value) <> 'string'
    ) OR jsonb_array_length(p_moves) <> jsonb_array_length(COALESCE(selected_game.moves, '[]'::jsonb)) + 1 THEN
      RAISE EXCEPTION 'Move history is invalid' USING ERRCODE = '22023';
    END IF;

    UPDATE public.games
    SET fen = p_next_fen,
        moves = p_moves,
        pgn = p_pgn,
        result = p_result,
        status = CASE WHEN p_result = 'in_progress' THEN 'in_progress' ELSE 'completed' END,
        ended_at = CASE WHEN p_result = 'in_progress' THEN NULL ELSE NOW() END,
        updated_at = NOW()
    WHERE id = p_game_id
    RETURNING * INTO selected_game;
  ELSIF p_action = 'resign' THEN
    p_result := CASE
      WHEN p_actor_id = selected_game.white_player_id THEN 'black_wins'
      ELSE 'white_wins'
    END;
    UPDATE public.games
    SET result = p_result,
        status = 'completed',
        ended_at = NOW(),
        updated_at = NOW()
    WHERE id = p_game_id
    RETURNING * INTO selected_game;
  ELSE
    RAISE EXCEPTION 'Invalid game action' USING ERRCODE = '22023';
  END IF;

  IF selected_game.status <> 'completed' THEN
    RETURN jsonb_build_object('status', selected_game.status, 'result', selected_game.result);
  END IF;

  IF COALESCE(selected_game.rated, true) = false
    OR selected_game.result = 'abandoned'
    OR selected_game.result = 'in_progress' THEN
    UPDATE public.games
    SET white_rating_change = 0, black_rating_change = 0
    WHERE id = p_game_id;
    RETURN jsonb_build_object(
      'status', selected_game.status,
      'result', selected_game.result,
      'whiteRatingChange', 0,
      'blackRatingChange', 0
    );
  END IF;

  rating_format := CASE
    WHEN selected_game.format IS NOT NULL THEN selected_game.format
    WHEN selected_game.time_control = '1+0' THEN 'bullet'
    WHEN selected_game.time_control IN ('3+0', '3+2', '5+0') THEN 'blitz'
    WHEN selected_game.time_control IN ('10+0', '10+5') THEN 'rapid'
    ELSE 'classical'
  END;

  INSERT INTO public.player_ratings (profile_id, format)
  VALUES (selected_game.white_player_id, rating_format),
         (selected_game.black_player_id, rating_format)
  ON CONFLICT (profile_id, format) DO NOTHING;

  SELECT w.rating, b.rating
  INTO white_previous, black_previous
  FROM public.player_ratings w
  JOIN public.player_ratings b
    ON b.profile_id = selected_game.black_player_id
   AND b.format = rating_format
  WHERE w.profile_id = selected_game.white_player_id
    AND w.format = rating_format
  FOR UPDATE OF w, b;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'A participant rating is missing' USING ERRCODE = '23503';
  END IF;

  white_change := CASE
    WHEN selected_game.result = 'white_wins' THEN 8
    WHEN selected_game.result = 'black_wins' THEN -8
    ELSE 0
  END;
  black_change := CASE
    WHEN selected_game.result = 'black_wins' THEN 8
    WHEN selected_game.result = 'white_wins' THEN -8
    ELSE 0
  END;
  white_change := GREATEST(-white_previous, white_change);
  black_change := GREATEST(-black_previous, black_change);

  UPDATE public.player_ratings
  SET rating = GREATEST(0, rating + white_change),
      highest_rating = GREATEST(highest_rating, GREATEST(0, rating + white_change)),
      lowest_rating = LEAST(lowest_rating, GREATEST(0, rating + white_change)),
      games_played = games_played + 1,
      wins = wins + CASE WHEN selected_game.result = 'white_wins' THEN 1 ELSE 0 END,
      losses = losses + CASE WHEN selected_game.result = 'black_wins' THEN 1 ELSE 0 END,
      draws = draws + CASE WHEN selected_game.result = 'draw' THEN 1 ELSE 0 END,
      updated_at = NOW()
  WHERE profile_id = selected_game.white_player_id AND format = rating_format;

  UPDATE public.player_ratings
  SET rating = GREATEST(0, rating + black_change),
      highest_rating = GREATEST(highest_rating, GREATEST(0, rating + black_change)),
      lowest_rating = LEAST(lowest_rating, GREATEST(0, rating + black_change)),
      games_played = games_played + 1,
      wins = wins + CASE WHEN selected_game.result = 'black_wins' THEN 1 ELSE 0 END,
      losses = losses + CASE WHEN selected_game.result = 'white_wins' THEN 1 ELSE 0 END,
      draws = draws + CASE WHEN selected_game.result = 'draw' THEN 1 ELSE 0 END,
      updated_at = NOW()
  WHERE profile_id = selected_game.black_player_id AND format = rating_format;

  UPDATE public.profiles
  SET rating = GREATEST(0, rating + white_change),
      games_played = games_played + 1,
      wins = wins + CASE WHEN selected_game.result = 'white_wins' THEN 1 ELSE 0 END,
      losses = losses + CASE WHEN selected_game.result = 'black_wins' THEN 1 ELSE 0 END,
      draws = draws + CASE WHEN selected_game.result = 'draw' THEN 1 ELSE 0 END,
      updated_at = NOW()
  WHERE id = selected_game.white_player_id;

  UPDATE public.profiles
  SET rating = GREATEST(0, rating + black_change),
      games_played = games_played + 1,
      wins = wins + CASE WHEN selected_game.result = 'black_wins' THEN 1 ELSE 0 END,
      losses = losses + CASE WHEN selected_game.result = 'white_wins' THEN 1 ELSE 0 END,
      draws = draws + CASE WHEN selected_game.result = 'draw' THEN 1 ELSE 0 END,
      updated_at = NOW()
  WHERE id = selected_game.black_player_id;

  INSERT INTO public.rating_history (
    game_id, profile_id, format, previous_rating, new_rating, rating_change, result
  ) VALUES
    (p_game_id, selected_game.white_player_id, rating_format, white_previous,
     GREATEST(0, white_previous + white_change), white_change, selected_game.result),
    (p_game_id, selected_game.black_player_id, rating_format, black_previous,
     GREATEST(0, black_previous + black_change), black_change, selected_game.result)
  ON CONFLICT (game_id, profile_id) DO NOTHING;

  UPDATE public.games
  SET white_rating_change = white_change,
      black_rating_change = black_change
  WHERE id = p_game_id;

  RETURN jsonb_build_object(
    'status', selected_game.status,
    'result', selected_game.result,
    'format', rating_format,
    'whiteRatingChange', white_change,
    'blackRatingChange', black_change
  );
END;
$$;

REVOKE ALL ON FUNCTION public.apply_online_game_action(UUID, UUID, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_online_game_action(UUID, UUID, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT)
  TO authenticated;
