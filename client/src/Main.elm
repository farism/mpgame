module Main exposing (..)

import AnimationFrame
import Html as Html
import Html exposing (..)
import Html.Attributes exposing (value, placeholder, class)
import Html.Events exposing (onInput, onClick, onSubmit)
import Phoenix.Socket
import Phoenix.Channel
import Phoenix.Push
import Phoenix.Presence exposing (PresenceState, syncState, syncDiff, presenceStateDecoder, presenceDiffDecoder)
import Json.Encode as JE
import Json.Decode as JD
import Debug
import Dict exposing (Dict)
import Window
import Renderer


-- Our model will track a list of messages and the text for our new message to
-- send.  We only support chatting in a single channel for now.


type alias User =
    { name : String
    }


type alias UserPresence =
    { online_at : String
    , device : String
    }


type alias ChatMessage =
    { user : String
    , body : String
    }


type alias UserPosition =
    { user : String
    , x : Int
    , y : Int
    }


type alias Model =
    { newMessage : String
    , messages : List ChatMessage
    , username : String
    , users : List User
    , phxSocket : Maybe (Phoenix.Socket.Socket Msg)
    , phxPresences : PresenceState UserPresence
    , userPositions : List UserPosition
    , renderer : Renderer.Model
    }


type Msg
    = SetNewMessage String
    | JoinChannel
    | PhoenixMsg (Phoenix.Socket.Msg Msg)
    | SendMessage
    | ReceiveChatMessage JE.Value
    | SetUsername String
    | ConnectSocket
    | HandlePresenceState JE.Value
    | HandlePresenceDiff JE.Value
    | RendererMsg Renderer.Msg
    | ReceiveUserPositions JE.Value



-- | RendererMessage Renderer.Msg


initialModel : Model
initialModel =
    { newMessage = ""
    , messages = []
    , username = ""
    , users = []
    , phxSocket = Nothing
    , phxPresences = Dict.empty
    , userPositions =
        [ { x = 0, y = 0, user = "bob" }
        , { x = 10, y = 0, user = "john" }
        ]
    , renderer = Renderer.model
    }


socketServer : String -> String
socketServer username =
    "ws://localhost:4000/socket/websocket?username=" ++ username


initPhxSocket : String -> Phoenix.Socket.Socket Msg
initPhxSocket username =
    Phoenix.Socket.init (socketServer username)
        |> Phoenix.Socket.withDebug
        |> Phoenix.Socket.on "new:msg" "room:lobby" ReceiveChatMessage
        |> Phoenix.Socket.on "user:position" "room:lobby" ReceiveUserPositions
        |> Phoenix.Socket.on "presence_state" "room:lobby" HandlePresenceState
        |> Phoenix.Socket.on "presence_diff" "room:lobby" HandlePresenceDiff


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        SetNewMessage string ->
            { model | newMessage = string } ! []

        JoinChannel ->
            case model.phxSocket of
                Nothing ->
                    model ! []

                Just modelPhxSocket ->
                    let
                        channel =
                            Phoenix.Channel.init "room:lobby"

                        ( phxSocket, phxCmd ) =
                            Phoenix.Socket.join channel modelPhxSocket
                    in
                        ( { model | phxSocket = Just phxSocket }
                        , Cmd.map PhoenixMsg phxCmd
                        )

        PhoenixMsg msg ->
            case model.phxSocket of
                Nothing ->
                    model ! []

                Just modelPhxSocket ->
                    let
                        ( phxSocket, phxCmd ) =
                            Phoenix.Socket.update msg modelPhxSocket
                    in
                        ( { model | phxSocket = Just phxSocket }
                        , Cmd.map PhoenixMsg phxCmd
                        )

        SendMessage ->
            case model.phxSocket of
                Nothing ->
                    model ! []

                Just modelPhxSocket ->
                    let
                        payload =
                            (JE.object [ ( "body", JE.string model.newMessage ) ])

                        pushPrime =
                            Phoenix.Push.init "new:msg" "room:lobby"
                                |> Phoenix.Push.withPayload payload

                        ( phxSocket, phxCmd ) =
                            Phoenix.Socket.push pushPrime modelPhxSocket
                    in
                        ( { model
                            | newMessage = ""
                            , phxSocket = Just phxSocket
                          }
                        , Cmd.map PhoenixMsg phxCmd
                        )

        ReceiveChatMessage raw ->
            case JD.decodeValue chatMessageDecoder raw of
                Ok chatMessage ->
                    { model | messages = model.messages ++ [ chatMessage ] } ! []

                Err error ->
                    model ! []

        ReceiveUserPositions raw ->
            case JD.decodeValue userPositionsDecoder raw of
                Ok userPositions ->
                    { model | userPositions = userPositions }
                        ! []

                Err error ->
                    model ! []

        SetUsername username ->
            { model | username = username } ! []

        ConnectSocket ->
            { model | phxSocket = Just (initPhxSocket model.username) } ! []

        HandlePresenceState raw ->
            case JD.decodeValue (presenceStateDecoder userPresenceDecoder) raw of
                Ok presenceState ->
                    let
                        newPresenceState =
                            model.phxPresences |> syncState presenceState

                        users =
                            Dict.keys presenceState
                                |> List.map User
                    in
                        { model | users = users, phxPresences = newPresenceState } ! []

                Err error ->
                    let
                        _ =
                            Debug.log "Error" error
                    in
                        model ! []

        RendererMsg msg ->
            let
                _ =
                    Debug.log "renderermsg" msg

                ( renderer, rendererCmds ) =
                    Renderer.update msg model.renderer
            in
                ( { model | renderer = renderer }, Cmd.map RendererMsg rendererCmds )

        HandlePresenceDiff raw ->
            case JD.decodeValue (presenceDiffDecoder userPresenceDecoder) raw of
                Ok presenceDiff ->
                    let
                        newPresenceState =
                            model.phxPresences |> syncDiff presenceDiff

                        users =
                            Dict.keys newPresenceState
                                |> List.map User
                    in
                        { model | users = users, phxPresences = newPresenceState } ! []

                Err error ->
                    let
                        _ =
                            Debug.log "Error" error
                    in
                        model ! []


chatMessageDecoder : JD.Decoder ChatMessage
chatMessageDecoder =
    JD.map2 ChatMessage
        (JD.oneOf
            [ (JD.field "user" JD.string)
            , JD.succeed "anonymous"
            ]
        )
        (JD.field "body" JD.string)


userPositionDecoder : JD.Decoder UserPosition
userPositionDecoder =
    JD.map3
        UserPosition
        (JD.field "user" JD.string)
        (JD.field "x" JD.int)
        (JD.field "y" JD.int)


userPositionsDecoder : JD.Decoder (List UserPosition)
userPositionsDecoder =
    JD.list userPositionDecoder


userPresenceDecoder : JD.Decoder UserPresence
userPresenceDecoder =
    JD.map2 UserPresence
        (JD.field "online_at" JD.string)
        (JD.field "device" JD.string)


viewMessage : ChatMessage -> Html Msg
viewMessage message =
    div [ class "message" ]
        [ span [ class "user" ] [ text (message.user ++ ": ") ]
        , span [ class "body" ] [ text message.body ]
        ]


lobbyManagementView : Html Msg
lobbyManagementView =
    button [ onClick JoinChannel ] [ text "Join lobby" ]


messageListView : Model -> Html Msg
messageListView model =
    div [ class "messages" ]
        (List.map viewMessage model.messages)


messageInputView : Model -> Html Msg
messageInputView model =
    form [ onSubmit SendMessage ]
        [ input [ placeholder "Message...", onInput SetNewMessage, value model.newMessage ] [] ]


userListView : Model -> Html Msg
userListView model =
    ul [ class "users" ]
        (List.map userView model.users)


userView : User -> Html Msg
userView user =
    li []
        [ text user.name
        ]


rendererView : Model -> Html Msg
rendererView model =
    Html.map RendererMsg (Renderer.view model.renderer)


chatInterfaceView : Model -> Html Msg
chatInterfaceView model =
    div []
        [ lobbyManagementView
        , messageListView model
        , messageInputView model
        , userListView model
        , rendererView model
        ]


setUsernameView : Html Msg
setUsernameView =
    form [ onSubmit ConnectSocket ]
        [ input [ onInput SetUsername, placeholder "Enter a username" ] [] ]


view : Model -> Html Msg
view model =
    case model.phxSocket of
        Nothing ->
            setUsernameView

        _ ->
            chatInterfaceView model


main : Program Never Model Msg
main =
    Html.program
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }


subscriptions : Model -> Sub Msg
subscriptions model =
    case model.phxSocket of
        Nothing ->
            Sub.none

        Just phxSocket ->
            Sub.batch
                [ Phoenix.Socket.listen phxSocket PhoenixMsg
                , Sub.map RendererMsg Renderer.subscriptions
                ]


init : ( Model, Cmd Msg )
init =
    let
        ( initRenderer, rendererCmds ) =
            Renderer.init
    in
        ( initialModel, Cmd.map RendererMsg rendererCmds )
