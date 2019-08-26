module Game exposing (Model, Msg(..), init, update, viewBoard, viewEvents, viewKeycard, viewStatus)

import Api exposing (Event, Update)
import Array exposing (Array)
import Browser.Dom as Dom
import Cell exposing (Cell)
import Color exposing (Color)
import Dict
import Html exposing (Html, div, h3, i, li, span, text, ul)
import Html.Attributes as Attr
import Html.Events exposing (onClick)
import Html.Keyed as Keyed
import Html.Lazy exposing (lazy2, lazy3)
import Http
import Json.Decode as Dec
import Json.Encode as Enc
import Player exposing (Player)
import Side exposing (Side)
import Task
import User exposing (User)


init : Api.GameState -> User -> Api.Client -> (Msg -> msg) -> ( Model, Cmd msg )
init state user client toMsg =
    let
        model =
            List.foldl applyEvent
                { id = state.id
                , seed = state.seed
                , players = Dict.empty
                , events = []
                , cells =
                    List.map3 (\w l1 l2 -> ( w, ( False, l1 ), ( False, l2 ) ))
                        state.words
                        state.oneLayout
                        state.twoLayout
                        |> List.indexedMap (\i ( w, ( e1, l1 ), ( e2, l2 ) ) -> Cell i w ( e1, l1 ) ( e2, l2 ))
                        |> Array.fromList
                , player = { id = user.playerId, name = user.name, side = Nothing }
                , turn = Nothing
                , tokensConsumed = 0
                , client = client
                , keyView = ShowWords
                }
                state.events

        player =
            { id = user.playerId, name = user.name, side = Dict.get user.playerId model.players }

        modelWithPlayer =
            { model | player = player }
    in
    ( modelWithPlayer, Cmd.batch [ longPollEvents modelWithPlayer toMsg, jumpToBottom "events" toMsg ] )



------ MODEL ------


type alias Model =
    { id : String
    , seed : String
    , players : Dict.Dict String Side
    , events : List Api.Event
    , cells : Array Cell
    , player : Player
    , turn : Maybe Side
    , tokensConsumed : Int
    , client : Api.Client
    , keyView : KeyView
    }


type KeyView
    = ShowWords
    | ShowKeycard


type Status
    = Start
    | InProgress Side Int Int
    | Lost Int
    | Won Int


lastEvent : Model -> Int
lastEvent m =
    m.events
        |> List.head
        |> Maybe.map (\x -> x.number)
        |> Maybe.withDefault 0


status : Model -> Status
status g =
    let
        greens =
            remainingGreen g.cells
    in
    case g.turn of
        Nothing ->
            Start

        Just turn ->
            if exposedBlack <| Array.toList <| g.cells then
                Lost greens

            else if greens == 0 then
                Won g.tokensConsumed

            else
                InProgress turn greens g.tokensConsumed


remainingGreen : Array Cell -> Int
remainingGreen cells =
    15
        - (cells
            |> Array.map Cell.display
            |> Array.filter (\x -> x == Cell.ExposedGreen)
            |> Array.length
          )


exposedBlack : List Cell -> Bool
exposedBlack cells =
    cells
        |> List.map Cell.display
        |> List.any (\x -> x == Cell.ExposedBlack)



------ UPDATE ------


type Msg
    = NoOp
    | LongPoll String String (Result Http.Error Api.Update)
    | GameUpdate (Result Http.Error Api.Update)
    | WordPicked Cell
    | ToggleKeyView KeyView


update : Msg -> Model -> (Msg -> msg) -> Maybe ( Model, Cmd msg )
update msg model toMsg =
    case msg of
        NoOp ->
            Just ( model, Cmd.none )

        LongPoll id seed result ->
            case ( id == model.id && seed == model.seed, result ) of
                ( False, _ ) ->
                    -- We might get the result of a long poll from a previous
                    -- game we were playing, in which case we just want to
                    -- ignore it.
                    Just ( model, Cmd.none )

                ( True, Err e ) ->
                    -- Even if the long poll request failed for some reason,
                    -- we want to trigger a new request anyways. The failure
                    -- could be short-lived.
                    -- TODO: add exponential backoff
                    Just ( model, longPollEvents model toMsg )

                ( True, Ok up ) ->
                    applyUpdate model up toMsg
                        |> Maybe.map (\( m, cmd ) -> ( m, Cmd.batch [ cmd, longPollEvents m toMsg ] ))

        GameUpdate (Ok up) ->
            applyUpdate model up toMsg

        GameUpdate (Err err) ->
            -- TODO: flash an error message?
            Just ( model, Cmd.none )

        ToggleKeyView newSetting ->
            Just ( { model | keyView = newSetting }, Cmd.none )

        WordPicked cell ->
            case model.player.side of
                Nothing ->
                    Just ( model, Cmd.none )

                Just side ->
                    Just
                        ( model
                        , if not (Cell.isExposed (Side.opposite side) cell) then
                            Api.submitGuess
                                { gameId = model.id
                                , seed = model.seed
                                , player = model.player
                                , index = cell.index
                                , lastEventId = lastEvent model
                                , toMsg = \x -> toMsg (GameUpdate x)
                                , client = model.client
                                }

                          else
                            Cmd.none
                        )


applyUpdate : Model -> Update -> (Msg -> msg) -> Maybe ( Model, Cmd msg )
applyUpdate model up toMsg =
    if up.seed /= model.seed then
        -- If the seed doesn't match, the previous game was destroyed
        -- and replaced with a new game.
        Nothing

    else
        let
            newModel =
                List.foldl applyEvent model up.events
        in
        Just
            ( newModel
            , if lastEvent newModel > lastEvent model then
                jumpToBottom "events" toMsg

              else
                Cmd.none
            )


applyEvent : Event -> Model -> Model
applyEvent e model =
    if e.number <= lastEvent model then
        model

    else
        case e.typ of
            "join_side" ->
                { model | players = Dict.update e.playerId (\_ -> e.side) model.players, events = e :: model.events }

            "player_left" ->
                { model | players = Dict.update e.playerId (\_ -> Nothing) model.players, events = e :: model.events }

            "guess" ->
                case ( Array.get e.index model.cells, e.side ) of
                    ( Just cell, Just side ) ->
                        applyGuess e cell side model

                    _ ->
                        { model | events = e :: model.events }

            _ ->
                { model | events = e :: model.events }


applyGuess : Event -> Cell -> Side -> Model -> Model
applyGuess e cell side model =
    { model
        | cells = Array.set e.index (Cell.tapped side cell) model.cells
        , events = e :: model.events
        , turn =
            if Cell.oppColor side cell == Color.Tan then
                Just (Side.opposite side)

            else
                Just side
        , tokensConsumed =
            case ( model.turn == Just (Side.opposite side), Cell.oppColor side cell ) of
                ( True, Color.Tan ) ->
                    -- If it's the other side's turn, we need to consume one
                    -- token to end the previous side's turn at guessing.
                    -- If the currently guessing team hit a tan, they're
                    -- done guessing and we need to consume a second.
                    model.tokensConsumed + 2

                ( _, Color.Tan ) ->
                    model.tokensConsumed + 1

                ( True, _ ) ->
                    model.tokensConsumed + 1

                _ ->
                    model.tokensConsumed
    }


longPollEvents : Model -> (Msg -> msg) -> Cmd msg
longPollEvents m toMsg =
    Api.longPollEvents
        { gameId = m.id
        , seed = m.seed
        , player = m.player
        , lastEventId = lastEvent m
        , tracker = m.id ++ m.seed
        , toMsg = \x -> toMsg (LongPoll m.id m.seed x)
        , client = m.client
        }



------ VIEW ------


jumpToBottom : String -> (Msg -> msg) -> Cmd msg
jumpToBottom id toMsg =
    Dom.getViewportOf id
        |> Task.andThen (\info -> Dom.setViewportOf id 0 info.scene.height)
        |> Task.attempt (always (toMsg NoOp))


viewStatus : Model -> Html a
viewStatus model =
    case status model of
        Start ->
            div [ Attr.id "status", Attr.class "in-progress" ]
                [ div [] [ text "Either side may give the first clue!" ] ]

        Lost _ ->
            div [ Attr.id "status", Attr.class "lost" ]
                [ div [] [ text "You lost :(" ] ]

        Won _ ->
            div [ Attr.id "status", Attr.class "won" ]
                [ div [] [ text "You won!" ] ]

        InProgress turn greens tokensConsumed ->
            div [ Attr.id "status", Attr.class "in-progress" ]
                [ div [] [ text (String.fromInt greens), span [ Attr.class "green-icon" ] [] ]
                , div [] [ text (String.fromInt tokensConsumed), text " ", i [ Attr.class "icon ion-ios-time" ] [] ]
                ]


viewBoard : Model -> Html Msg
viewBoard model =
    Keyed.node "div"
        [ Attr.id "board"
        , Attr.classList
            [ ( "no-team", model.player.side == Nothing )
            ]
        ]
        (model.cells
            |> Array.toList
            |> List.map (\c -> ( c.word, lazy3 Cell.view model.player.side WordPicked c ))
        )


viewEvents : Model -> Html Msg
viewEvents model =
    Keyed.node "div"
        [ Attr.id "events" ]
        (model.events
            |> List.reverse
            |> List.map (\e -> ( String.fromInt e.number, lazy2 viewEvent model e ))
        )


viewEvent : Model -> Event -> Html Msg
viewEvent model e =
    case e.typ of
        "join_side" ->
            div []
                [ text e.name
                , text " has joined side "
                , text (e.side |> Maybe.map Side.toString |> Maybe.withDefault "")
                , text "."
                ]

        "player_left" ->
            div [] [ text e.name, text " has left the game." ]

        "guess" ->
            Array.get e.index model.cells
                |> Maybe.map2
                    (\s c ->
                        div []
                            [ text "Side "
                            , text (Side.toString s)
                            , text " tapped "
                            , span [ Attr.class "chat-color", Attr.class (Color.toString (Cell.oppColor s c)) ] [ text c.word ]
                            , text "."
                            ]
                    )
                    e.side
                |> Maybe.withDefault (text "")

        "chat" ->
            let
                sideEl =
                    case e.side of
                        Just s ->
                            span [ Attr.class "side" ] [ text (" (" ++ Side.toString s ++ ")") ]

                        Nothing ->
                            text ""
            in
            div [] [ text e.name, sideEl, text ": ", text e.message ]

        _ ->
            text ""


viewKeycard : Model -> Side -> Html Msg
viewKeycard model side =
    case model.keyView of
        ShowWords ->
            let
                cells =
                    Array.toList model.cells

                cellsOf =
                    \color -> List.filter (\c -> Cell.sideColor side c == color) cells
            in
            div [ Attr.id "key-list", onClick (ToggleKeyView ShowKeycard) ]
                [ ul [ Attr.class "greens" ]
                    (cellsOf Color.Green
                        |> List.map (\x -> li [ Attr.classList [ ( "crossed", Cell.isExposedAll x ) ] ] [ text x.word ])
                    )
                , ul [ Attr.class "blacks" ]
                    (cellsOf Color.Black
                        |> List.map (\x -> li [ Attr.classList [ ( "crossed", Cell.isExposed side x || Cell.isExposedAll x ) ] ] [ text x.word ])
                    )
                , ul [ Attr.class "tans" ]
                    (cellsOf Color.Tan
                        |> List.take 7
                        |> List.map (\x -> li [ Attr.classList [ ( "crossed", Cell.isExposed side x || Cell.isExposedAll x ) ] ] [ text x.word ])
                    )
                , ul [ Attr.class "tans" ]
                    (cellsOf Color.Tan
                        |> List.drop 7
                        |> List.map (\x -> li [ Attr.classList [ ( "crossed", Cell.isExposed side x || Cell.isExposedAll x ) ] ] [ text x.word ])
                    )
                ]

        ShowKeycard ->
            div [ Attr.id "key-card", onClick (ToggleKeyView ShowWords) ]
                (model.cells
                    |> Array.toList
                    |> List.map
                        (\c ->
                            div
                                [ Attr.classList
                                    [ ( "cell", True )
                                    , ( Color.toString <| Cell.sideColor side <| c, True )
                                    , ( "crossed", Cell.isExposed side c || Cell.isExposedAll c )
                                    ]
                                ]
                                []
                        )
                )
