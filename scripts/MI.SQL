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

------------------------------------------------------------------------------

WITH match_scores AS (
    SELECT
        match_id,
        MIN(start_date)                                              AS match_date,
        MAX(CASE WHEN batting_team = 'Mumbai Indians' THEN venue END) AS venue,
        SUM(CASE WHEN batting_team = 'Mumbai Indians'
                 THEN runs_off_bat + extras ELSE 0 END)             AS mi_score,
        SUM(CASE WHEN batting_team != 'Mumbai Indians'
                 THEN runs_off_bat + extras ELSE 0 END)             AS opp_score,
        MAX(CASE WHEN batting_team != 'Mumbai Indians'
                 THEN batting_team END)                             AS opponent,
                 
        -- NEW COLUMNS NEEDED FOR YOUR UPDATED LOGIC
        MAX(CASE WHEN innings = 1 THEN batting_team END)            AS first_batting_team,
        SUM(CASE WHEN innings = 2 
                  AND batting_team != 'Mumbai Indians' 
                  AND wicket_type IS NOT NULL THEN 1 ELSE 0 END)    AS opp_inn2_wickets
                  
    FROM deliveries
    WHERE batting_team = 'Mumbai Indians'
       OR bowling_team = 'Mumbai Indians'
    GROUP BY match_id
)
SELECT
    match_id,
    match_date,
    opponent,
    mi_score,
    opp_score,
    mi_score - opp_score                                            AS run_diff,
    CASE WHEN mi_score > opp_score THEN 'WIN' ELSE 'LOSS' END       AS result,
    CASE WHEN mi_score < opp_score
         THEN CONCAT('Lost by ', (opp_score - mi_score), ' runs')
         ELSE CONCAT('Won by ',  (mi_score - opp_score),  ' runs')
    END                                                             AS margin,
    
    -- ✅ CORRECT failure_category logic (Merged)
    CASE
        WHEN mi_score > opp_score THEN '✅ WIN'
        -- MI batted first, opponent chased with many wickets = bowling failure
        WHEN first_batting_team = 'Mumbai Indians'
            AND (10 - opp_inn2_wickets) >= 5
            THEN '🔴 Bowling Failure — Couldn''t Defend'
        -- MI chased but fell short by big margin = batting collapse
        WHEN first_batting_team != 'Mumbai Indians'
            AND (opp_score - mi_score) >= 30
            THEN '⚫ Heavy Loss — Batting Collapse'
        -- MI chased and fell short by small margin
        WHEN first_batting_team != 'Mumbai Indians'
            THEN '🟠 Narrow Loss — Bowling/Batting'
        ELSE '⚫ Heavy Loss — Total Collapse'
    END                                                             AS failure_category

FROM match_scores
ORDER BY match_date;

-------------------------------------------------------------------------------------------

SELECT
    striker                                                         AS batsman,
    COUNT(DISTINCT match_id)                                        AS innings,
    SUM(runs_off_bat)                                               AS total_runs,
 
    -- balls faced = deliveries where no wide
    COUNT(CASE WHEN COALESCE(wides, 0) = 0 THEN 1 END)             AS balls_faced,
 
    -- highest score in a single innings
    MAX(inn_runs)                                                   AS highest_score,
 
    SUM(CASE WHEN runs_off_bat = 4 THEN 1 ELSE 0 END)              AS fours,
    SUM(CASE WHEN runs_off_bat = 6 THEN 1 ELSE 0 END)              AS sixes,
 
    ROUND(
        SUM(runs_off_bat) * 100.0
        / NULLIF(COUNT(CASE WHEN COALESCE(wides, 0) = 0 THEN 1 END), 0),
        1
    )                                                               AS strike_rate,
 
    ROUND(
        SUM(runs_off_bat) * 1.0
        / NULLIF(COUNT(DISTINCT match_id), 0),
        1
    )                                                               AS avg_per_innings,
 
    -- boundary dominance %
    ROUND(
        SUM(CASE WHEN runs_off_bat IN (4,6)
                 THEN runs_off_bat ELSE 0 END) * 100.0
        / NULLIF(SUM(runs_off_bat), 0),
        1
    )                                                               AS boundary_run_pct
 
FROM deliveries
INNER JOIN (
    -- pre-aggregate to get highest innings score per player
    SELECT striker AS s, match_id AS m, SUM(runs_off_bat) AS inn_runs
    FROM deliveries
    WHERE batting_team = 'Mumbai Indians'
    GROUP BY striker, match_id
) hs ON hs.s = striker AND hs.m = match_id
 
WHERE batting_team = 'Mumbai Indians'
GROUP BY striker
HAVING SUM(runs_off_bat) > 0
ORDER BY total_runs DESC;

-------------------------------------------------------------------------------------------------------

WITH match_result AS (
    -- Step 1: Safely calculate if MI won or lost each match at the team level
    SELECT match_id,
           CASE WHEN SUM(CASE WHEN batting_team='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
                     > SUM(CASE WHEN batting_team!='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
                THEN 'WIN' ELSE 'LOSS' END AS result
    FROM deliveries
    WHERE batting_team='Mumbai Indians' OR bowling_team='Mumbai Indians'
    GROUP BY match_id
),
batsman_match AS (
    -- Step 2: Calculate each batsman's individual score per match
    SELECT
        striker,
        match_id,
        SUM(runs_off_bat)                                         AS match_runs,
        COUNT(CASE WHEN COALESCE(wides, 0) = 0 THEN 1 END)        AS balls
    FROM deliveries
    WHERE batting_team = 'Mumbai Indians'
    GROUP BY striker, match_id
)
-- Step 3: Combine them to expose the "Talent Paradox"
SELECT
    bm.striker                                                      AS batsman,
    COUNT(bm.match_id)                                              AS total_innings,

    -- IN WINS
    ROUND(AVG(CASE WHEN mr.result = 'WIN'  THEN bm.match_runs END), 1)   AS avg_in_wins,
    SUM(CASE WHEN mr.result = 'WIN'  THEN 1 ELSE 0 END)                  AS win_innings,

    -- IN LOSSES
    ROUND(AVG(CASE WHEN mr.result = 'LOSS' THEN bm.match_runs END), 1)   AS avg_in_losses,
    SUM(CASE WHEN mr.result = 'LOSS' THEN 1 ELSE 0 END)                  AS loss_innings,

    -- THE GAP (The bigger this is, the more the player vanishes in tough games)
    ROUND(
        AVG(CASE WHEN mr.result='WIN'  THEN bm.match_runs END) -
        AVG(CASE WHEN mr.result='LOSS' THEN bm.match_runs END),
        1
    )                                                                    AS win_loss_gap,

    -- PLAYER VERDICT
    CASE
        WHEN AVG(CASE WHEN mr.result='WIN'  THEN bm.match_runs END)
             > AVG(CASE WHEN mr.result='LOSS' THEN bm.match_runs END) * 1.5
             THEN '⚠️ Flat Track Bully — needs to perform in losses'
        WHEN AVG(CASE WHEN mr.result='LOSS' THEN bm.match_runs END)
             >= AVG(CASE WHEN mr.result='WIN'  THEN bm.match_runs END)
             THEN '💪 Fighter — performs even in losses'
        ELSE '⚖️ Consistent'
    END                                                                  AS player_verdict

FROM batsman_match bm
JOIN match_result mr ON bm.match_id = mr.match_id
GROUP BY bm.striker
HAVING COUNT(bm.match_id) >= 3
ORDER BY avg_in_losses DESC;

-----------------------------------------------------------------------------------------------

WITH match_result AS (
    SELECT
        match_id,
        CASE
            WHEN SUM(CASE WHEN batting_team='Mumbai Indians'
                          THEN runs_off_bat + extras ELSE 0 END)
                 > SUM(CASE WHEN batting_team!='Mumbai Indians'
                            THEN runs_off_bat + extras ELSE 0 END)
            THEN 'WIN' ELSE 'LOSS'
        END AS result
    FROM deliveries
    WHERE batting_team='Mumbai Indians' OR bowling_team='Mumbai Indians'
    GROUP BY match_id
)
SELECT
    mr.result,
    CASE
        WHEN FLOOR(d.ball) BETWEEN 0 AND 5   THEN 'Powerplay (Ov 1-6)'
        WHEN FLOOR(d.ball) BETWEEN 6 AND 14  THEN 'Middle (Ov 7-15)'
        ELSE                                      'Death (Ov 16-20)'
    END                                                             AS phase,
 
    COUNT(DISTINCT d.match_id)                                      AS matches,
    ROUND(SUM(d.runs_off_bat + d.extras) / COUNT(DISTINCT d.match_id), 1)
                                                                    AS avg_phase_runs,
    ROUND(SUM(CASE WHEN d.wicket_type IS NOT NULL THEN 1 ELSE 0 END)
          / COUNT(DISTINCT d.match_id), 1)                         AS avg_wickets_lost,
    ROUND(
        SUM(d.runs_off_bat + d.extras) * 6.0
        / NULLIF(COUNT(CASE WHEN COALESCE(d.wides,0)=0
                             AND COALESCE(d.noballs,0)=0 THEN 1 END), 0),
        2
    )                                                               AS phase_run_rate
 
FROM deliveries d
INNER JOIN match_result mr ON mr.match_id = d.match_id
WHERE d.batting_team = 'Mumbai Indians'
GROUP BY mr.result, phase
ORDER BY
    mr.result DESC,
    CASE phase
        WHEN 'Powerplay (Ov 1-6)'  THEN 1
        WHEN 'Middle (Ov 7-15)'    THEN 2
        ELSE 3
    END;

-------------------------------------------------------------------------------------------------

WITH match_result AS (
    SELECT match_id,
           CASE WHEN SUM(CASE WHEN batting_team='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
                     > SUM(CASE WHEN batting_team!='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
                THEN 'WIN' ELSE 'LOSS' END AS result,
           MAX(CASE WHEN batting_team != 'Mumbai Indians' THEN batting_team END) AS opponent
    FROM deliveries
    WHERE batting_team='Mumbai Indians' OR bowling_team='Mumbai Indians'
    GROUP BY match_id
)
SELECT
    d.match_id,
    MIN(d.start_date)                                               AS match_date,
    mr.opponent,
    mr.result,
    SUM(d.runs_off_bat + d.extras)                                  AS pp_runs,
    SUM(CASE WHEN d.wicket_type IS NOT NULL THEN 1 ELSE 0 END)      AS pp_wickets,
    ROUND(SUM(d.runs_off_bat + d.extras) * 6.0 /
          NULLIF(COUNT(CASE WHEN COALESCE(d.wides,0)=0
                             AND COALESCE(d.noballs,0)=0 THEN 1 END), 0), 2)
                                                                    AS pp_run_rate,
    -- grade the powerplay
    CASE
        WHEN SUM(CASE WHEN d.wicket_type IS NOT NULL THEN 1 ELSE 0 END) >= 3
             THEN '🔴 Collapse (3+ wickets)'
        WHEN SUM(CASE WHEN d.wicket_type IS NOT NULL THEN 1 ELSE 0 END) = 2
             THEN '🟠 Shaky (2 wickets)'
        ELSE '✅ Solid'
    END                                                             AS pp_status
 
FROM deliveries d
INNER JOIN match_result mr ON mr.match_id = d.match_id
WHERE d.batting_team = 'Mumbai Indians'
  AND FLOOR(d.ball) BETWEEN 0 AND 5
GROUP BY d.match_id, mr.opponent, mr.result
ORDER BY mr.result DESC, pp_wickets DESC;

-----------------------------------------------------------------------------------------

WITH mi_batting_balls AS (
    SELECT
        d.match_id,
        d.start_date,
        d.ball,
        d.striker,
        d.runs_off_bat,
        d.extras,
        d.runs_off_bat + d.extras                                   AS ball_runs,
        d.wicket_type,
        d.player_dismissed,
        -- running total score within innings
        SUM(d.runs_off_bat + d.extras)
            OVER (PARTITION BY d.match_id
                  ORDER BY d.ball
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS score_at_ball,
        -- wicket sequence number
        SUM(CASE WHEN d.wicket_type IS NOT NULL THEN 1 ELSE 0 END)
            OVER (PARTITION BY d.match_id
                  ORDER BY d.ball
                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS wicket_number
    FROM deliveries d
    WHERE d.batting_team = 'Mumbai Indians'
),
wicket_balls_only AS (
    SELECT *,
        -- runs scored between this wicket and the previous one
        score_at_ball - LAG(score_at_ball, 1, 0)
            OVER (PARTITION BY match_id ORDER BY ball)              AS runs_between_wickets
    FROM mi_batting_balls
    WHERE wicket_type IS NOT NULL
)
SELECT
    w.match_id,
    w.start_date                                                    AS match_date,
    w.wicket_number,
    CONCAT(FLOOR(w.ball)+1, '.', ROUND((w.ball - FLOOR(w.ball)) * 10))
                                                                    AS over_ball,                                                               
    w.player_dismissed,
    w.wicket_type,
    w.score_at_ball                                                 AS score_at_dismissal,
    w.runs_between_wickets,
    -- flag dangerous collapses: < 10 runs between consecutive wickets
    
    CASE
        WHEN w.runs_between_wickets < 10 AND w.wicket_number > 1
             THEN '🔴 Cluster Wicket — Collapse Zone'
        WHEN w.runs_between_wickets < 20 AND w.wicket_number > 1
             THEN '🟠 Quick Wicket'
        ELSE '✅ Partnership Built'
    END                                                             AS collapse_flag
FROM wicket_balls_only w
ORDER BY w.match_id, w.wicket_number;

--------------------------------------------------------------------------------------------

WITH match_result AS (
    SELECT match_id,
           CASE WHEN SUM(CASE WHEN batting_team='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
                     > SUM(CASE WHEN batting_team!='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
                THEN 'WIN' ELSE 'LOSS' END AS result
    FROM deliveries
    WHERE batting_team='Mumbai Indians' OR bowling_team='Mumbai Indians'
    GROUP BY match_id
)
SELECT
    d.match_id,
    mr.result,
    SUM(d.runs_off_bat + d.extras)                                  AS death_runs,
    SUM(CASE WHEN d.wicket_type IS NOT NULL THEN 1 ELSE 0 END)      AS death_wickets,
    SUM(CASE WHEN d.runs_off_bat = 6 THEN 1 ELSE 0 END)            AS sixes,
    SUM(CASE WHEN d.runs_off_bat = 4 THEN 1 ELSE 0 END)            AS fours,
    ROUND(SUM(d.runs_off_bat + d.extras) * 6.0 /
          NULLIF(COUNT(CASE WHEN COALESCE(d.wides,0)=0
                             AND COALESCE(d.noballs,0)=0 THEN 1 END), 0), 2)
                                                                    AS death_run_rate,
    CASE
        WHEN SUM(d.runs_off_bat + d.extras) >= 60 THEN '✅ Excellent finish (60+)'
        WHEN SUM(d.runs_off_bat + d.extras) >= 45 THEN '🟡 Good finish (45-59)'
        WHEN SUM(d.runs_off_bat + d.extras) >= 30 THEN '🟠 Below par (30-44)'
        ELSE                                            '🔴 Poor finish (<30)'
    END                                                             AS finish_grade
 
FROM deliveries d
INNER JOIN match_result mr ON mr.match_id = d.match_id
WHERE d.batting_team = 'Mumbai Indians'
  AND FLOOR(d.ball) BETWEEN 15 AND 19
GROUP BY d.match_id, mr.result
ORDER BY mr.result DESC, death_runs DESC;

-------------------------------------------------------------------------------------------------------

SELECT
    bowler,
    COUNT(DISTINCT match_id)                                        AS matches,
 
    -- bowler wickets (exclude run outs & retired)
    SUM(CASE WHEN wicket_type IS NOT NULL
              AND wicket_type NOT IN ('run out','retired hurt',
                                      'retired out','obstructing the field')
              AND bowling_team = 'Mumbai Indians'
             THEN 1 ELSE 0 END)                                     AS wickets,
 
    -- legal balls (no wides, no no-balls)
    COUNT(CASE WHEN COALESCE(wides,0)=0
                AND COALESCE(noballs,0)=0 THEN 1 END)               AS balls_bowled,
 
    ROUND(COUNT(CASE WHEN COALESCE(wides,0)=0
                      AND COALESCE(noballs,0)=0 THEN 1 END) / 6.0, 1)
                                                                    AS overs_bowled,
 
    -- runs conceded = runs off bat + wides + no-balls
    SUM(runs_off_bat + COALESCE(wides,0) + COALESCE(noballs,0))     AS runs_conceded,
 
    ROUND(
        SUM(runs_off_bat + COALESCE(wides,0) + COALESCE(noballs,0)) * 6.0
        / NULLIF(COUNT(CASE WHEN COALESCE(wides,0)=0
                             AND COALESCE(noballs,0)=0 THEN 1 END), 0),
        2
    )                                                               AS economy,
 
    ROUND(
        SUM(runs_off_bat + COALESCE(wides,0) + COALESCE(noballs,0)) * 1.0
        / NULLIF(SUM(CASE WHEN wicket_type IS NOT NULL
                           AND wicket_type NOT IN ('run out','retired hurt',
                                                   'retired out','obstructing the field')
                          THEN 1 ELSE 0 END), 0),
        1
    )                                                               AS bowling_avg,
 
    ROUND(
        COUNT(CASE WHEN COALESCE(wides,0)=0
                    AND COALESCE(noballs,0)=0 THEN 1 END) * 1.0
        / NULLIF(SUM(CASE WHEN wicket_type IS NOT NULL
                           AND wicket_type NOT IN ('run out','retired hurt',
                                                   'retired out','obstructing the field')
                          THEN 1 ELSE 0 END), 0),
        1
    )                                                               AS bowling_sr,

    -- NEW COLUMNS ADDED HERE
    SUM(COALESCE(wides, 0))                                         AS wides,
    SUM(COALESCE(noballs, 0))                                       AS noballs,
 
    -- grade
    CASE
        WHEN ROUND(SUM(runs_off_bat+COALESCE(wides,0)+COALESCE(noballs,0))*6.0
             / NULLIF(COUNT(CASE WHEN COALESCE(wides,0)=0 AND COALESCE(noballs,0)=0 THEN 1 END),0),2)
             <= 8.0  THEN '🟢 Elite'
        WHEN ROUND(SUM(runs_off_bat+COALESCE(wides,0)+COALESCE(noballs,0))*6.0
             / NULLIF(COUNT(CASE WHEN COALESCE(wides,0)=0 AND COALESCE(noballs,0)=0 THEN 1 END),0),2)
             <= 9.5  THEN '🟡 Good'
        WHEN ROUND(SUM(runs_off_bat+COALESCE(wides,0)+COALESCE(noballs,0))*6.0
             / NULLIF(COUNT(CASE WHEN COALESCE(wides,0)=0 AND COALESCE(noballs,0)=0 THEN 1 END),0),2)
             <= 11.0 THEN '🟠 Average'
        ELSE              '🔴 Expensive'
    END                                                             AS economy_grade
 
FROM deliveries
WHERE bowling_team = 'Mumbai Indians'
GROUP BY bowler
HAVING balls_bowled >= 6    -- minimum 1 over
ORDER BY wickets DESC, economy ASC;

------------------------------------------------------------------------------------------------------------------

WITH match_result AS (
    SELECT match_id,
           CASE WHEN SUM(CASE WHEN batting_team='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
                     > SUM(CASE WHEN batting_team!='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
                THEN 'WIN' ELSE 'LOSS' END AS result
    FROM deliveries
    WHERE batting_team='Mumbai Indians' OR bowling_team='Mumbai Indians'
    GROUP BY match_id
)
SELECT
    d.bowler,
    COUNT(DISTINCT d.match_id)                                      AS death_matches,
    COUNT(CASE WHEN COALESCE(d.wides,0)=0
               AND COALESCE(d.noballs,0)=0 THEN 1 END)             AS death_balls,
    ROUND(COUNT(CASE WHEN COALESCE(d.wides,0)=0
                      AND COALESCE(d.noballs,0)=0 THEN 1 END)/6.0,1)
                                                                    AS death_overs,
    SUM(d.runs_off_bat + COALESCE(d.wides,0)
                       + COALESCE(d.noballs,0))                    AS death_runs,
    ROUND(
        SUM(d.runs_off_bat + COALESCE(d.wides,0) + COALESCE(d.noballs,0)) * 6.0
        / NULLIF(COUNT(CASE WHEN COALESCE(d.wides,0)=0
                             AND COALESCE(d.noballs,0)=0 THEN 1 END), 0),
        2
    )                                                               AS death_economy,
    SUM(CASE WHEN d.wicket_type IS NOT NULL
              AND d.wicket_type NOT IN ('run out','retired hurt','retired out')
             THEN 1 ELSE 0 END)                                    AS death_wickets,
    SUM(CASE WHEN d.runs_off_bat = 6 THEN 1 ELSE 0 END)           AS sixes_conceded,
 
    -- in losses only
    ROUND(
        SUM(CASE WHEN mr.result='LOSS'
                 THEN d.runs_off_bat+COALESCE(d.wides,0)+COALESCE(d.noballs,0)
                 ELSE 0 END) * 6.0
        / NULLIF(SUM(CASE WHEN mr.result='LOSS'
                           AND COALESCE(d.wides,0)=0
                           AND COALESCE(d.noballs,0)=0 THEN 1 ELSE 0 END), 0),
        2
    )                                                               AS death_economy_in_losses,
 
    CASE
        WHEN ROUND(SUM(d.runs_off_bat+COALESCE(d.wides,0)+COALESCE(d.noballs,0))*6.0
             /NULLIF(COUNT(CASE WHEN COALESCE(d.wides,0)=0 AND COALESCE(d.noballs,0)=0 THEN 1 END),0),2)
             <= 8.5  THEN '✅ Bumrah-class'
        WHEN ROUND(SUM(d.runs_off_bat+COALESCE(d.wides,0)+COALESCE(d.noballs,0))*6.0
             /NULLIF(COUNT(CASE WHEN COALESCE(d.wides,0)=0 AND COALESCE(d.noballs,0)=0 THEN 1 END),0),2)
             <= 10.0 THEN '🟡 Acceptable'
        ELSE              '🔴 Liability in Death'
    END                                                             AS death_verdict
 
FROM deliveries d
INNER JOIN match_result mr ON mr.match_id = d.match_id
WHERE d.bowling_team = 'Mumbai Indians'
  AND FLOOR(d.ball) BETWEEN 15 AND 19
GROUP BY d.bowler
HAVING COUNT(CASE WHEN COALESCE(d.wides,0)=0
                   AND COALESCE(d.noballs,0)=0 THEN 1 END) >= 6
ORDER BY death_economy ASC;

------------------------------------------------------------------------------------------------------------

WITH match_result AS (
    SELECT match_id,
           MAX(CASE WHEN batting_team!='Mumbai Indians' THEN batting_team END) AS opponent,
           SUM(CASE WHEN batting_team='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END) AS mi_score,
           SUM(CASE WHEN batting_team!='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END) AS opp_score
    FROM deliveries
    WHERE batting_team='Mumbai Indians' OR bowling_team='Mumbai Indians'
    GROUP BY match_id
)
SELECT
    d.match_id,
    MIN(d.start_date)                                               AS match_date,
    mr.opponent,
    CASE WHEN mr.mi_score > mr.opp_score THEN 'WIN' ELSE 'LOSS' END AS result,
    mr.opp_score - mr.mi_score                                     AS loss_margin,
    SUM(COALESCE(d.wides,  0))                                     AS wides_given,
    SUM(COALESCE(d.noballs,0))                                     AS noballs_given,
    SUM(COALESCE(d.byes,   0))                                     AS byes_given,
    SUM(COALESCE(d.legbyes,0))                                     AS legbyes_given,
    SUM(d.extras)                                                  AS total_extras,
 
    -- THE KEY BUSINESS INSIGHT
    CASE
        WHEN mr.mi_score >= mr.opp_score
             THEN '✅ Won — extras did not decide match'
        WHEN SUM(d.extras) >= (mr.opp_score - mr.mi_score)
             THEN '🚨 EXTRAS DIRECTLY COST THIS MATCH'
        WHEN SUM(d.extras) >= (mr.opp_score - mr.mi_score) * 0.5
             THEN '⚠️  Extras were a major loss factor'
        ELSE '❌ Lost — other failure was primary cause'
    END                                                             AS extras_verdict
 
FROM deliveries d
INNER JOIN match_result mr ON mr.match_id = d.match_id
WHERE d.bowling_team = 'Mumbai Indians'
GROUP BY d.match_id, mr.opponent, mr.mi_score, mr.opp_score
ORDER BY CASE WHEN mr.mi_score < mr.opp_score THEN 0 ELSE 1 END, total_extras DESC;

----------------------------------------------------------------------------------------

WITH match_result AS (
    SELECT match_id,
           MAX(CASE WHEN batting_team!='Mumbai Indians' THEN batting_team END) AS opponent,
           CASE WHEN SUM(CASE WHEN batting_team='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
                     > SUM(CASE WHEN batting_team!='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
                THEN 'WIN' ELSE 'LOSS' END AS result
    FROM deliveries
    WHERE batting_team='Mumbai Indians' OR bowling_team='Mumbai Indians'
    GROUP BY match_id
)
SELECT
    d.match_id,
    MIN(d.start_date)                                               AS match_date,
    mr.opponent,
    mr.result,
    SUM(d.runs_off_bat + d.extras)                                  AS runs_conceded,
    COUNT(CASE WHEN COALESCE(d.wides,0)=0
               AND COALESCE(d.noballs,0)=0 THEN 1 END)             AS legal_balls,
    SUM(CASE WHEN d.wicket_type IS NOT NULL
              AND d.wicket_type NOT IN ('run out','retired hurt','retired out')
             THEN 1 ELSE 0 END)                                    AS wickets_taken,
    ROUND(
        SUM(d.runs_off_bat + d.extras) * 6.0
        / NULLIF(COUNT(CASE WHEN COALESCE(d.wides,0)=0
                             AND COALESCE(d.noballs,0)=0 THEN 1 END), 0),
        2
    )                                                               AS team_economy,
    CASE
        WHEN ROUND(SUM(d.runs_off_bat+d.extras)*6.0/NULLIF(COUNT(CASE WHEN COALESCE(d.wides,0)=0 AND COALESCE(d.noballs,0)=0 THEN 1 END),0),2) <= 8.5
             THEN '✅ Excellent bowl'
        WHEN ROUND(SUM(d.runs_off_bat+d.extras)*6.0/NULLIF(COUNT(CASE WHEN COALESCE(d.wides,0)=0 AND COALESCE(d.noballs,0)=0 THEN 1 END),0),2) <= 10
             THEN '🟡 Acceptable'
        ELSE '🔴 Expensive — attack failed'
    END                                                             AS bowling_verdict
FROM deliveries d
INNER JOIN match_result mr ON mr.match_id = d.match_id
WHERE d.bowling_team = 'Mumbai Indians'
GROUP BY d.match_id, mr.opponent, mr.result
ORDER BY mr.result DESC, team_economy ASC;

---------------------------------------------------------------------------------------------------------------------

WITH match_info AS (
    -- 1. Calculate the Opponent and Match Result once per match
    SELECT 
        match_id,
        MAX(CASE WHEN batting_team != 'Mumbai Indians' THEN batting_team
                 WHEN bowling_team != 'Mumbai Indians' THEN bowling_team END) AS opponent,
        CASE WHEN SUM(CASE WHEN batting_team = 'Mumbai Indians' THEN runs_off_bat + extras ELSE 0 END) 
                > SUM(CASE WHEN batting_team != 'Mumbai Indians' THEN runs_off_bat + extras ELSE 0 END)
             THEN 'WIN' ELSE 'LOSS' END AS result
    FROM deliveries
    WHERE batting_team = 'Mumbai Indians' OR bowling_team = 'Mumbai Indians'
    GROUP BY match_id
),
over_runs AS (
    -- 2. Your original over-by-over grouping
    SELECT
        match_id,
        batting_team,
        FLOOR(ball)                                                 AS over_no,
        SUM(runs_off_bat + extras)                                  AS over_total,
        SUM(CASE WHEN wicket_type IS NOT NULL THEN 1 ELSE 0 END)    AS over_wickets
    FROM deliveries
    WHERE batting_team = 'Mumbai Indians'
       OR bowling_team  = 'Mumbai Indians'
    GROUP BY match_id, batting_team, FLOOR(ball)
)
SELECT
    o.match_id,
    m.opponent,
    m.result,
    o.batting_team,
    o.over_no + 1                                                   AS over_number,
    o.over_total,
    o.over_wickets,
 
    -- previous over runs (LAG)
    LAG(o.over_total) OVER (
        PARTITION BY o.match_id, o.batting_team
        ORDER BY o.over_no
    )                                                               AS prev_over_runs,
 
    -- momentum change
    o.over_total - LAG(o.over_total) OVER (
        PARTITION BY o.match_id, o.batting_team
        ORDER BY o.over_no
    )                                                               AS run_change_vs_prev_over,
 
    -- running total
    SUM(o.over_total) OVER (
        PARTITION BY o.match_id, o.batting_team
        ORDER BY o.over_no
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                               AS cumulative_runs,
 
    -- cumulative wickets
    SUM(o.over_wickets) OVER (
        PARTITION BY o.match_id, o.batting_team
        ORDER BY o.over_no
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                               AS cumulative_wickets,
 
    -- flag momentum shifts
    CASE
        WHEN o.over_wickets >= 2 THEN '🔴 Multi-wicket over'
        WHEN o.over_total = 0    THEN '⚫ Dot over (maiden)'
        WHEN o.over_total >= 15  THEN '🟢 Big over (15+)'
        WHEN o.over_total <= 4 AND FLOOR(o.over_no) BETWEEN 15 AND 19
             THEN '🔴 Death stall'
        ELSE '⚪ Normal'
    END                                                             AS over_flag
 
FROM over_runs o
INNER JOIN match_info m ON o.match_id = m.match_id
ORDER BY o.match_id, o.batting_team, o.over_no;

-----------------------------------------------------------------------------------------------------

WITH player_match AS (
    SELECT
        d.match_id,
        -- batting
        d.striker                                                   AS player,
        'bat'                                                       AS role,
        SUM(d.runs_off_bat)                                         AS runs,
        COUNT(CASE WHEN COALESCE(d.wides,0)=0 THEN 1 END)           AS balls,
        0                                                           AS wickets,
        0                                                           AS runs_conceded_bowl
    FROM deliveries d
    WHERE d.batting_team = 'Mumbai Indians'
    GROUP BY d.match_id, d.striker
 
    UNION ALL
 
    SELECT
        d.match_id,
        d.bowler,
        'bowl',
        0,
        -- BUG FIX: Actually count the bowler's legal deliveries here instead of '0'
        COUNT(CASE WHEN COALESCE(d.wides,0)=0 AND COALESCE(d.noballs,0)=0 THEN 1 END),
        SUM(CASE WHEN d.wicket_type IS NOT NULL
                  AND d.wicket_type NOT IN ('run out','retired hurt','retired out')
                 THEN 1 ELSE 0 END),
        SUM(d.runs_off_bat + COALESCE(d.wides,0) + COALESCE(d.noballs,0))
    FROM deliveries d
    WHERE d.bowling_team = 'Mumbai Indians'
    GROUP BY d.match_id, d.bowler
),
match_result AS (
    SELECT match_id,
           CASE WHEN SUM(CASE WHEN batting_team='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
                     > SUM(CASE WHEN batting_team!='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
                THEN 'WIN' ELSE 'LOSS' END AS result
    FROM deliveries
    WHERE batting_team='Mumbai Indians' OR bowling_team='Mumbai Indians'
    GROUP BY match_id
)
SELECT
    pm.player,
    COUNT(DISTINCT pm.match_id)                                     AS matches,
 
    -- batting impact
    SUM(pm.runs)                                                    AS total_runs,
    ROUND(AVG(CASE WHEN mr.result='WIN'  THEN pm.runs END), 1)      AS avg_bat_wins,
    ROUND(AVG(CASE WHEN mr.result='LOSS' THEN pm.runs END), 1)      AS avg_bat_losses,
 
    -- bowling impact
    SUM(pm.wickets)                                                 AS total_wickets,
    ROUND(
        SUM(pm.runs_conceded_bowl) * 6.0
        -- SYNTAX FIX: Replaced FILTER with MySQL-friendly CASE WHEN
        / NULLIF(SUM(CASE WHEN pm.role='bowl' THEN pm.balls ELSE 0 END), 0)
        , 2
    )                                                               AS economy,
 
    -- composite CRUNCH INDEX (works for both allrounders and specialists)
    ROUND(
        (SUM(pm.runs) * ROUND(SUM(pm.runs)*100.0/NULLIF(SUM(CASE WHEN pm.role='bat' THEN pm.balls ELSE 0 END),0),1) / 100)
        + (SUM(pm.wickets) * 10)
        - (SUM(pm.runs_conceded_bowl)*6.0 / NULLIF(SUM(CASE WHEN pm.role='bowl' THEN pm.balls ELSE 0 END),0))
        , 1
    )                                                               AS crunch_impact_index,
 
    -- verdict
    CASE
        WHEN ROUND(AVG(CASE WHEN mr.result='WIN' THEN pm.runs END),1)
             > ROUND(AVG(CASE WHEN mr.result='LOSS' THEN pm.runs END),1) * 1.5
             THEN '⚠️ Vanishes in tough matches'
        WHEN SUM(pm.runs) = 0 AND SUM(pm.wickets) >= 3
             THEN '🎳 Pure bowler — assess separately'
        WHEN ROUND(AVG(CASE WHEN mr.result='LOSS' THEN pm.runs END),1)
             >= ROUND(AVG(CASE WHEN mr.result='WIN' THEN pm.runs END),1)
             THEN '💪 Fights in defeats'
        ELSE '⚖️ Consistent'
    END                                                             AS impact_verdict
 
FROM player_match pm
INNER JOIN match_result mr ON mr.match_id = pm.match_id
GROUP BY pm.player
HAVING SUM(pm.runs) >= 30 OR SUM(pm.wickets) >= 3
ORDER BY crunch_impact_index DESC;

--------------------------------------------------------------------------------------------------------------------------

WITH match_result AS (
    SELECT match_id,
           CASE WHEN SUM(CASE WHEN batting_team='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
                     > SUM(CASE WHEN batting_team!='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
                THEN 'WIN' ELSE 'LOSS' END AS result
    FROM deliveries
    WHERE batting_team='Mumbai Indians' OR bowling_team='Mumbai Indians'
    GROUP BY match_id
)
SELECT
    d.striker,
    d.non_striker,
    d.match_id,
    mr.result,
    SUM(d.runs_off_bat + d.extras)                                  AS partnership_runs,
    COUNT(CASE WHEN COALESCE(d.wides,0)=0
               AND COALESCE(d.noballs,0)=0 THEN 1 END)             AS balls_faced,
    ROUND(SUM(d.runs_off_bat+d.extras)*6.0 /
          NULLIF(COUNT(CASE WHEN COALESCE(d.wides,0)=0
                             AND COALESCE(d.noballs,0)=0 THEN 1 END),0), 1)
                                                                    AS partnership_rr,
    SUM(CASE WHEN d.runs_off_bat = 6 THEN 1 ELSE 0 END)           AS sixes
FROM deliveries d
INNER JOIN match_result mr ON mr.match_id = d.match_id
WHERE d.batting_team = 'Mumbai Indians'
GROUP BY d.striker, d.non_striker, d.match_id, mr.result
HAVING partnership_runs >= 20
ORDER BY partnership_runs DESC
LIMIT 20;

----------------------------------------------------------------------------------------------------------------------

WITH lost_matches AS (
    SELECT match_id
    FROM deliveries
    WHERE batting_team='Mumbai Indians' OR bowling_team='Mumbai Indians'
    GROUP BY match_id
    HAVING SUM(CASE WHEN batting_team='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
           < SUM(CASE WHEN batting_team!='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END)
)
SELECT
    d.bowler,
    COUNT(DISTINCT d.match_id)                                     AS matches_in_losses,
    SUM(d.runs_off_bat + COALESCE(d.wides,0) + COALESCE(d.noballs,0))
                                                                   AS runs_conceded,
    COUNT(CASE WHEN COALESCE(d.wides,0)=0
               AND COALESCE(d.noballs,0)=0 THEN 1 END)            AS balls,
    SUM(CASE WHEN d.wicket_type IS NOT NULL
              AND d.wicket_type NOT IN ('run out','retired hurt','retired out')
             THEN 1 ELSE 0 END)                                   AS wickets,
    ROUND(
        SUM(d.runs_off_bat+COALESCE(d.wides,0)+COALESCE(d.noballs,0)) * 6.0
        / NULLIF(COUNT(CASE WHEN COALESCE(d.wides,0)=0
                             AND COALESCE(d.noballs,0)=0 THEN 1 END), 0),
        2
    )                                                              AS economy_in_losses,
    RANK() OVER (
        ORDER BY
        SUM(d.runs_off_bat+COALESCE(d.wides,0)+COALESCE(d.noballs,0)) * 6.0
        / NULLIF(COUNT(CASE WHEN COALESCE(d.wides,0)=0
                             AND COALESCE(d.noballs,0)=0 THEN 1 END), 0)
        DESC
    )                                                              AS costliest_rank
FROM deliveries d
INNER JOIN lost_matches lm ON lm.match_id = d.match_id
WHERE d.bowling_team = 'Mumbai Indians'
GROUP BY d.bowler
HAVING balls >= 6
ORDER BY economy_in_losses DESC;

-------------------------------------------------------------------------------------------

WITH match_summary AS (
    SELECT
        match_id,
        MIN(start_date)                                             AS match_date,
        MAX(venue)                                                  AS venue,
        SUM(CASE WHEN batting_team='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END) AS mi_score,
        SUM(CASE WHEN batting_team!='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END) AS opp_score,
        MAX(CASE WHEN batting_team!='Mumbai Indians' THEN batting_team END) AS opponent,
        SUM(CASE WHEN bowling_team='Mumbai Indians' THEN extras ELSE 0 END) AS mi_extras_given,
        SUM(CASE WHEN bowling_team='Mumbai Indians'
                  AND FLOOR(ball) BETWEEN 15 AND 19
                 THEN runs_off_bat+COALESCE(wides,0)+COALESCE(noballs,0) ELSE 0 END) AS death_runs_given,
        SUM(CASE WHEN batting_team='Mumbai Indians'
                  AND FLOOR(ball) BETWEEN 0 AND 5
                  AND wicket_type IS NOT NULL THEN 1 ELSE 0 END)   AS pp_wickets_lost,
        SUM(CASE WHEN batting_team='Mumbai Indians'
                  AND FLOOR(ball) BETWEEN 15 AND 19
                 THEN runs_off_bat+extras ELSE 0 END)              AS mi_death_runs,
                 
        -- --- NEW ADDITIONS FOR CORRECT MARGINS ---
        MAX(CASE WHEN innings = 2 THEN batting_team END)           AS team_batting_second,
        SUM(CASE WHEN batting_team != 'Mumbai Indians' 
                  AND wicket_type IS NOT NULL THEN 1 ELSE 0 END)   AS opp_wickets_lost,
        MAX(CASE WHEN innings = 2 THEN ball END)                   AS final_ball_bowled
        
    FROM deliveries
    WHERE batting_team='Mumbai Indians' OR bowling_team='Mumbai Indians'
    GROUP BY match_id
)
SELECT
    match_id,
    match_date,
    opponent,
    mi_score,
    opp_score,
    opp_score - mi_score                                            AS lost_by,
    mi_extras_given,
    death_runs_given,
    pp_wickets_lost,
    mi_death_runs,
 
    -- EXTRAS CHECK — did free runs hand the match?
    CASE
        WHEN mi_extras_given >= (opp_score - mi_score)
             THEN '🚨 YES — Extras alone exceeded losing margin'
        WHEN mi_extras_given >= (opp_score - mi_score) * 0.7
             THEN '⚠️  Extras were decisive factor'
        ELSE '❌ No — other factors were primary'
    END                                                             AS did_extras_cost_match,
 
    -- DEATH BOWLING CHECK
    CASE
        WHEN death_runs_given > 60 THEN '🔴 Death bowling leaked 60+ runs'
        WHEN death_runs_given > 50 THEN '🟠 Death bowling under pressure'
        ELSE '✅ Death bowling acceptable'
    END                                                             AS death_bowl_assessment,
 
    -- ROOT CAUSE
    CASE
        WHEN mi_extras_given >= (opp_score - mi_score)
             THEN 'ROOT CAUSE: Extras gifted the match'
        WHEN pp_wickets_lost >= 3
             THEN 'ROOT CAUSE: Powerplay collapse capped total'
        WHEN death_runs_given > 60
             THEN 'ROOT CAUSE: Death bowling leaked too many'
        ELSE 'ROOT CAUSE: Marginal execution failure (last over)'
    END                                                             AS root_cause,

    -- --- NEW ADDITIONS FOR CORRECT MARGINS TABLE ---
    
    -- 1. WHO CHASED
    CASE
        WHEN team_batting_second != 'Mumbai Indians'
        THEN opponent || ' chased ' || (mi_score + 1) || ' / Finished over ' || final_ball_bowled
        ELSE 'MI chased ' || (opp_score + 1) || ' / MI all out or fell short'
    END                                                             AS who_chased,

    -- 2. WRONG MARGIN (To show the flawed math)
    (opp_score - mi_score) || ' runs'                               AS wrong_margin,

    -- 3. CORRECT MARGIN (Wickets if opponent chased, Runs if MI chased)
    CASE
        WHEN team_batting_second != 'Mumbai Indians'
        THEN (10 - opp_wickets_lost) || ' wickets'
        ELSE (opp_score - mi_score) || ' runs'
    END                                                             AS correct_margin,

    -- 4. TYPE (Categorization)
    CASE
        WHEN team_batting_second != 'Mumbai Indians' THEN 'NOT a close loss'
        WHEN (opp_score - mi_score) >= 100 THEN 'Total collapse'
        WHEN (opp_score - mi_score) >= 20 THEN 'Batting collapse'
        ELSE 'Bowling gave too many'
    END                                                             AS match_type

FROM match_summary
WHERE mi_score < opp_score
  -- Note: If you want to see the massive 104-run loss in your dashboard, 
  -- you will need to remove or comment out the line below!
  AND (opp_score - mi_score) <= 10
ORDER BY lost_by ASC;

----------------------------------------------------------------------------------------------------------

--- Combined Batting and Bowling Wickets
SELECT 
    'MI Batting - Dismissal Types' AS analysis_type,
    wicket_type,
    COUNT(*) AS count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM deliveries
WHERE batting_team = 'Mumbai Indians'
  AND wicket_type IS NOT NULL
GROUP BY wicket_type

UNION ALL

SELECT 
    'MI Bowling - Wicket Types' AS analysis_type,
    wicket_type,
    COUNT(*) AS count,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct
FROM deliveries
WHERE bowling_team = 'Mumbai Indians'
  AND wicket_type IS NOT NULL
  AND wicket_type NOT IN ('run out', 'retired hurt', 'retired out')
GROUP BY wicket_type
ORDER BY analysis_type, count DESC;

--------------------------------------------------------------------------------------------------------------

WITH match_summary AS (
    SELECT
        match_id,
        MIN(start_date) AS match_date,
        MAX(CASE WHEN batting_team!='Mumbai Indians' THEN batting_team END) AS opponent,
        SUM(CASE WHEN batting_team='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END) AS mi_score,
        SUM(CASE WHEN batting_team!='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END) AS opp_score
    FROM deliveries
    WHERE batting_team='Mumbai Indians' OR bowling_team='Mumbai Indians'
    GROUP BY match_id
)
SELECT
    opponent,
    COUNT(*)                                                        AS matches,
    SUM(CASE WHEN mi_score > opp_score THEN 1 ELSE 0 END)         AS mi_wins,
    SUM(CASE WHEN mi_score < opp_score THEN 1 ELSE 0 END)         AS mi_losses,
    ROUND(AVG(mi_score),  1)                                       AS avg_mi_score,
    ROUND(AVG(opp_score), 1)                                       AS avg_opp_score,
    ROUND(AVG(mi_score - opp_score), 1)                           AS avg_run_diff
FROM match_summary
GROUP BY opponent
ORDER BY mi_losses DESC, avg_run_diff ASC;

-------------------------------------------------------------------------------------------------------------------

SELECT
    bowling_team,
    COUNT(DISTINCT match_id)                                        AS matches,
    ROUND(
        SUM(runs_off_bat + COALESCE(wides,0) + COALESCE(noballs,0)) * 6.0
        / NULLIF(COUNT(CASE WHEN COALESCE(wides,0)=0
                             AND COALESCE(noballs,0)=0 THEN 1 END), 0),
        2
    )                                                               AS death_economy,
    RANK() OVER (
        ORDER BY
        SUM(runs_off_bat+COALESCE(wides,0)+COALESCE(noballs,0)) * 6.0
        / NULLIF(COUNT(CASE WHEN COALESCE(wides,0)=0 AND COALESCE(noballs,0)=0 THEN 1 END),0)
        ASC
    )                                                               AS rank_best,
 
    CASE WHEN bowling_team = 'Mumbai Indians'
         THEN '← MI  (investigate this rank)'
         ELSE '' END                                                AS note
 
FROM deliveries
WHERE FLOOR(ball) BETWEEN 15 AND 19
GROUP BY bowling_team
ORDER BY death_economy ASC;

------------------------------------------------------------------------------------------------------------------------

SELECT
    bowling_team,
    COUNT(DISTINCT match_id)                                        AS matches,
    SUM(COALESCE(wides,0))                                         AS total_wides,
    SUM(COALESCE(noballs,0))                                       AS total_noballs,
    SUM(extras)                                                    AS total_extras,
    ROUND(SUM(extras) / COUNT(DISTINCT match_id), 1)               AS extras_per_match,
    RANK() OVER (
        ORDER BY SUM(extras) / COUNT(DISTINCT match_id) DESC
    )                                                               AS rank_worst_discipline,
    CASE WHEN bowling_team = 'Mumbai Indians'
         THEN '← MI  (8.4 extras/match — check this)'
         ELSE '' END                                                AS note
FROM deliveries
GROUP BY bowling_team
ORDER BY extras_per_match DESC;

---------------------------------------------------------------------------------------------------------------------------

SELECT
    ms.match_id,
    ms.match_date,
    ms.opponent,
    CASE WHEN ms.mi_score > ms.opp_score THEN 'WIN' ELSE 'LOSS' END AS result,
    ms.mi_score,
    ms.opp_score,
    ms.opp_score - ms.mi_score                                     AS loss_margin_runs,
 
    -- FACTOR 1: Powerplay Batting
    pp_bat.pp_runs                                                  AS f1_pp_runs,
    pp_bat.pp_wickets                                              AS f1_pp_wickets,
 
    -- FACTOR 2: Death Batting
    death_bat.death_runs                                            AS f2_death_bat_runs,
 
    -- FACTOR 3: Death Bowling
    ROUND(death_bowl.death_runs_given * 6.0
          / NULLIF(death_bowl.death_legal_balls, 0), 2)            AS f3_death_economy,
 
    -- FACTOR 4: Extras Given
    ext.extras_given                                               AS f4_extras_given,
 
    -- FACTOR 5: Key Player Scores (Rickelton + Tilak — top 2)
    top_bat.rickelton_runs                                         AS f5_rickelton,
    top_bat.tilak_runs                                             AS f5_tilak,
 
    -- COMPOSITE FAILURE MODE
    CASE
        WHEN ms.mi_score > ms.opp_score               THEN '✅ WIN'
        WHEN pp_bat.pp_wickets >= 3                   THEN '🔴 PP Collapse → Low Total'
        WHEN ROUND(death_bowl.death_runs_given*6.0/NULLIF(death_bowl.death_legal_balls,0),2) >= 12
                                                      THEN '🔴 Death Bowling Failure'
        WHEN ext.extras_given >= (ms.opp_score-ms.mi_score)
                                                      THEN '🔴 Extras Cost Match'
        WHEN death_bat.death_runs < 35                THEN '🟠 Poor Death Batting'
        ELSE                                               '🟡 Marginal — Execution'
    END                                                            AS primary_failure_mode
 
FROM (
    SELECT match_id, MIN(start_date) match_date,
           MAX(CASE WHEN batting_team!='Mumbai Indians' THEN batting_team END) opponent,
           SUM(CASE WHEN batting_team='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END) mi_score,
           SUM(CASE WHEN batting_team!='Mumbai Indians' THEN runs_off_bat+extras ELSE 0 END) opp_score
    FROM deliveries
    WHERE batting_team='Mumbai Indians' OR bowling_team='Mumbai Indians'
    GROUP BY match_id
) ms
 
LEFT JOIN (
    SELECT match_id,
           SUM(runs_off_bat+extras) pp_runs,
           SUM(CASE WHEN wicket_type IS NOT NULL THEN 1 ELSE 0 END) pp_wickets
    FROM deliveries
    WHERE batting_team='Mumbai Indians' AND FLOOR(ball) BETWEEN 0 AND 5
    GROUP BY match_id
) pp_bat ON pp_bat.match_id = ms.match_id
 
LEFT JOIN (
    SELECT match_id, SUM(runs_off_bat+extras) death_runs
    FROM deliveries
    WHERE batting_team='Mumbai Indians' AND FLOOR(ball) BETWEEN 15 AND 19
    GROUP BY match_id
) death_bat ON death_bat.match_id = ms.match_id
 
LEFT JOIN (
    SELECT match_id,
           SUM(runs_off_bat+COALESCE(wides,0)+COALESCE(noballs,0)) death_runs_given,
           COUNT(CASE WHEN COALESCE(wides,0)=0 AND COALESCE(noballs,0)=0 THEN 1 END) death_legal_balls
    FROM deliveries
    WHERE bowling_team='Mumbai Indians' AND FLOOR(ball) BETWEEN 15 AND 19
    GROUP BY match_id
) death_bowl ON death_bowl.match_id = ms.match_id
 
LEFT JOIN (
    SELECT match_id, SUM(extras) extras_given
    FROM deliveries
    WHERE bowling_team='Mumbai Indians'
    GROUP BY match_id
) ext ON ext.match_id = ms.match_id
 
LEFT JOIN (
    SELECT match_id,
           SUM(CASE WHEN striker='RD Rickelton' THEN runs_off_bat ELSE 0 END) rickelton_runs,
           SUM(CASE WHEN striker='Tilak Varma'   THEN runs_off_bat ELSE 0 END) tilak_runs
    FROM deliveries
    WHERE batting_team='Mumbai Indians'
    GROUP BY match_id
) top_bat ON top_bat.match_id = ms.match_id
 
ORDER BY ms.match_date;

---------------------------------------------------------------------------------------------------------------

SELECT 1 AS priority,
       'The Collapse Problem'                                                AS root_cause,
       'Only 1 narrow defeat by runs; remaining 9 losses were heavy collapses or chased with wickets in hand'  AS evidence,
       'When MI loses, they collapse completely — mental resilience is missing' AS insight,
       'Address structural collapses. Focus on middle-over partnership building' AS recommendation

UNION ALL SELECT 2,
       'Death Bowling Economy',
       'Conceded massive runs in overs 16-20 in majority of losses',
       'Without Bumrah, every other MI bowler leaks in death',
       'Sign 1 specialist death bowler. Bumrah cannot cover alone'

UNION ALL SELECT 3,
       'Extras Issue',
       'Extras: 130 in 14 matches',
       'Free runs gifted = multiple complete overs worth of scoring',
       'Targeted wide-reduction drills. Reduce to <5 extras per match'

UNION ALL SELECT 4,
       'Star Players Disappear During Collapses',
       'Tilak avg 15.20 in losses. Rickelton 26.20',
       'Stars score big only in comfortable wins — not when it counts',
       'High-pressure net sessions. Simulate deficit chases regularly'

UNION ALL SELECT 5,
       'Powerplay Collapses',
       'Lost 3+ wickets in PP in multiple losses',
       'Early collapse forces rebuild, limits final total',
       'Open with set batsmen. Protect wickets for first 2 overs'

UNION ALL SELECT 6,
       'Bowling Depth Beyond Bumrah',
       'Ghazanfar solid but pace support expensive in death',
       'Opponents target the non-Bumrah ends in key overs',
       'Rotate Bumrah into death overs. Protect his quota for overs 18-20'

UNION ALL SELECT 7,
       'FINAL VERDICT',
       '4W-10L with Rohit, Bumrah, Tilak, Rickelton, Hardik, de Kock in XI',
       'This is a PROCESS failure, not a TALENT failure',
       'T20 is won in 5 overs: 1-6 batting, 16-20 bowling. MI failed both'

ORDER BY priority;

---------------------------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------------------------
