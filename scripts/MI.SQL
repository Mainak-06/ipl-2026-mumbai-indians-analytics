USE ipl_analytics;

SELECT
    'Mumbai Indians'                                                AS team,
    COUNT(DISTINCT match_id)                                        AS matches_played,

    -- wins: MI batting team scored more than opponent in same match
    SUM(CASE WHEN result = 'WIN' THEN 1 ELSE 0 END)                 AS wins,
    SUM(CASE WHEN result = 'LOSS' THEN 1 ELSE 0 END)                AS losses,
    ROUND(SUM(CASE WHEN result='WIN' THEN 1 ELSE 0 END)
          * 100.0 / COUNT(DISTINCT match_id), 1)                    AS win_pct,

    -- close losses - the heartbreak stat
    SUM(CASE WHEN result = 'LOSS'
              AND ABS(mi_score - opp_score) <= 6  THEN 1 ELSE 0 END) AS losses_by_6_or_fewer_runs,
    SUM(CASE WHEN result = 'LOSS'
              AND ABS(mi_score - opp_score) <= 10 THEN 1 ELSE 0 END) AS losses_by_10_or_fewer_runs,

    ROUND(AVG(mi_score),  1)                                        AS avg_mi_score,
    ROUND(AVG(opp_score), 1)                                        AS avg_opp_score,
    ROUND(AVG(mi_score) - AVG(opp_score), 1)                        AS avg_run_differential,
    MIN(CASE WHEN result='LOSS' THEN ABS(mi_score-opp_score) END)   AS narrowest_loss_runs,
    MAX(CASE WHEN result='LOSS' THEN ABS(mi_score-opp_score) END)   AS biggest_loss_runs

FROM (
    -- subquery builds one row per match with MI score vs opponent score
    SELECT
        match_id,
        SUM(CASE WHEN batting_team = 'Mumbai Indians'
                 THEN runs_off_bat + extras ELSE 0 END)       AS mi_score,
        SUM(CASE WHEN batting_team != 'Mumbai Indians'
                 THEN runs_off_bat + extras ELSE 0 END)       AS opp_score,
        CASE
            WHEN SUM(CASE WHEN batting_team = 'Mumbai Indians'
                          THEN runs_off_bat + extras ELSE 0 END)
                 > SUM(CASE WHEN batting_team != 'Mumbai Indians'
                            THEN runs_off_bat + extras ELSE 0 END)
            THEN 'WIN' ELSE 'LOSS'
        END                                                          AS result
    FROM deliveries
    WHERE batting_team = 'Mumbai Indians'
       OR bowling_team = 'Mumbai Indians'
    GROUP BY match_id
) match_scores;