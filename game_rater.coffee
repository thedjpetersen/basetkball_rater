nba = require("nba.js")
Datastore = require("nedb")
Promise = require("bluebird")
moment = require("moment")
_ = require("lodash")
Table = require("cli-table")

db = new Datastore({filename: "./nba.db"})

data = nba.data
stats = nba.stats

init = () ->
    return new Promise (resolve, reject) ->
        # Check to see that we have the games saved
        db.find {}, (err, games) ->
            if games.length == 0
                fetch_games().done(() -> resolve())
            else
                resolve()

# Fetch all games and insert them in the database
fetch_games = () ->
    return new Promise (resolve, reject) ->
        data.schedule {year: 2016}, (err, res) ->
           games = res.league.standard
           db.insert(games)
           resolve();

get_game_info = (game, callback) ->
    if game.info
        callback.call(@, false)
        return

    game.gameDate = moment(game.startTimeUTC).format("YYYYMMDD")

    game.info = {leadtracker: {}}

    data.boxscore(game, (err, result) ->
        game.info.boxscore = result
        resolved = 0
        total_periods = result.basicGameData.period.current
        for periodNum in [1..total_periods]
            # Get the leadtracker
            game.periodNum = periodNum
            request_obj = _.extend({}, game)
            ((period) ->
                data.leadTracker(request_obj, (err, result) ->
                    game.info.leadtracker[period] = result

                    resolved++

                    if total_periods == resolved then callback.call(@, true)
                )
            )(periodNum)
    )

get_info_on_finished_games = () ->
    return new Promise (resolve, reject) ->
        db.find {"hTeam.score": {$ne: ""}, "info": {$exists: false}}, (err, games) ->
            if games.length == 0 then resolve(); return
            games_resolved = 0;
            for game in games
                ((gameRef) ->
                    get_game_info gameRef, (updated) ->
                        if updated
                            db.update({_id: gameRef._id}, {$set: gameRef}, {}, () ->
                                games_resolved++
                                if games_resolved == games.length
                                    resolve()
                            )
                        else
                            games_resolved++
                            if games_resolved == games.length
                                resolve()
                )(game)

score_game = (game) ->
    game_score = 0
    stats = game.info.boxscore.stats

    hScore = Number(game.hTeam.score)
    vScore = Number(game.vTeam.score)
    total_turnovers = Number(stats.hTeam.totals.turnovers) + Number(stats.vTeam.totals.turnovers)

    DIFFERENTIAL_WEIGHT = 10
    HIGH_SCORE_WEIGHT = 0.2

    score_factors =
        # Our point differential of the game
        # the number between the two teams
        POINT_DIFFERENTIAL: Math.abs(hScore - vScore)
        HIGH_SCORE: hScore + vScore - 180
        LEAD_CHANGES_TIES: Number(stats.timesTied) + Number(stats.leadChanges)
        CLOSE_THROUGHOUT: Number(stats.vTeam.biggestLead) < 10 && Number(stats.hTeam.biggestLead < 10)
        SLOPPINESS: (30-total_turnovers)*.2

    #console.log(game.info.leadtracker["4"])

    # Add our point differential to our score
    # give the differential a heavy weight
    game_score = (2/score_factors.POINT_DIFFERENTIAL)*DIFFERENTIAL_WEIGHT

    # We add or subtract points based on if the game was high scoring or not
    game_score += score_factors.HIGH_SCORE*HIGH_SCORE_WEIGHT

    # We add or subtract points based on if the game was high scoring or not
    game_score += score_factors.LEAD_CHANGES_TIES*HIGH_SCORE_WEIGHT

    # We add points for a clean game with a low number of turnovers
    # and we subtract them for a game with a high number of them
    game_score += score_factors.SLOPPINESS

    if score_factors.CLOSE_THROUGHOUT then game_score+2

    return game_score

score_games = () ->
    return new Promise (resolve, reject) ->
        db.find {"hTeam.score": {$ne: ""}, "info": {$exists: true}}, (err, games) ->
            table = new Table({
                head: ["Date", "Teams", "Entertainment Score"]
            })

            #score_game(games[0])
            for game in games
                game_score = score_game(game)

                # We only care about exciting games
                if game_score > 20
                    table.push([
                        moment(game.startTimeUTC).format("MM/DD/YYYY"),
                        game.info.boxscore.basicGameData.hTeam.triCode + " - " + game.info.boxscore.basicGameData.vTeam.triCode,
                        score_game(game)
                    ])

            console.log(table.toString())

db.loadDatabase (err) ->
    init()
        .then(get_info_on_finished_games)
        .then(score_games)
