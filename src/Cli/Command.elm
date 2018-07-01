module Cli.Command exposing (Command, CommandBuilder, build, buildWithDoc, captureRestOperands, expectFlag, flag, getUsageSpecs, hardcoded, keywordArgList, mapNew, matchResultToMaybe, optionalKeywordArg, positionalArg, requiredKeywordArg, subCommand, synopsis, toCommand, tryMatch, tryMatchNew, validate, validateIfPresent, with, withDefault)

import Cli.Decode
import Cli.Spec exposing (CliSpec(..))
import Cli.UsageSpec exposing (..)
import Cli.Validate exposing (ValidationResult(Invalid, Valid))
import List.Extra
import Occurences exposing (Occurences(..))
import Parser exposing (ParsedOption)


type MatchResult msg
    = Match (Result (List Cli.Decode.ValidationError) msg)
    | NoMatch (List String)


matchResultToMaybe : MatchResult msg -> Maybe (Result (List Cli.Decode.ValidationError) msg)
matchResultToMaybe matchResult =
    case matchResult of
        Match thing ->
            Just thing

        NoMatch unknownFlags ->
            Nothing


getUsageSpecs : Command decodesTo -> List UsageSpec
getUsageSpecs (Command { usageSpecs }) =
    usageSpecs


synopsis : String -> Command decodesTo -> String
synopsis programName command =
    command
        |> (\(Command record) -> record)
        |> Cli.UsageSpec.synopsis programName


tryMatchNew : List String -> Command msg -> MatchResult msg
tryMatchNew argv ((Command { decoder, usageSpecs, subCommand }) as command) =
    let
        decoder =
            command
                |> expectedOperandCountOrFail
                |> failIfUnexpectedOptions
                |> getDecoder

        flagsAndOperands =
            Parser.flagsAndOperands usageSpecs argv
                |> (\record ->
                        case ( subCommand, record.operands ) of
                            ( Nothing, _ ) ->
                                Ok
                                    { options = record.options
                                    , operands = record.operands
                                    , usageSpecs = usageSpecs
                                    }

                            ( Just subCommandName, actualSubCommand :: remainingOperands ) ->
                                if actualSubCommand == subCommandName then
                                    Ok
                                        { options = record.options
                                        , operands = remainingOperands
                                        , usageSpecs = usageSpecs
                                        }
                                else
                                    Err "Sub command does not match"

                            ( Just subCommandName, [] ) ->
                                Err "No sub command provided"
                   )
    in
    case flagsAndOperands of
        Ok actualFlagsAndOperands ->
            decoder actualFlagsAndOperands
                |> (\result ->
                        case result of
                            Err error ->
                                case error of
                                    Cli.Decode.MatchError matchError ->
                                        NoMatch []

                                    Cli.Decode.UnrecoverableValidationError validationError ->
                                        Match (Err [ validationError ])

                            Ok ( [], value ) ->
                                Match (Ok value)

                            Ok ( validationErrors, value ) ->
                                Match (Err validationErrors)
                   )

        Err _ ->
            NoMatch []


tryMatch : List String -> Command msg -> Maybe (Result (List Cli.Decode.ValidationError) msg)
tryMatch argv ((Command { decoder, usageSpecs, subCommand }) as command) =
    let
        decoder =
            command
                |> expectedOperandCountOrFail
                |> failIfUnexpectedOptions
                |> getDecoder

        flagsAndOperands =
            Parser.flagsAndOperands usageSpecs argv
                |> (\record ->
                        case ( subCommand, record.operands ) of
                            ( Nothing, _ ) ->
                                Ok
                                    { options = record.options
                                    , operands = record.operands
                                    , usageSpecs = usageSpecs
                                    }

                            ( Just subCommandName, actualSubCommand :: remainingOperands ) ->
                                if actualSubCommand == subCommandName then
                                    Ok
                                        { options = record.options
                                        , operands = remainingOperands
                                        , usageSpecs = usageSpecs
                                        }
                                else
                                    Err "Sub command does not match"

                            ( Just subCommandName, [] ) ->
                                Err "No sub command provided"
                   )
    in
    case flagsAndOperands of
        Ok actualFlagsAndOperands ->
            decoder actualFlagsAndOperands
                |> (\result ->
                        case result of
                            Err error ->
                                case error of
                                    Cli.Decode.MatchError matchError ->
                                        Nothing

                                    Cli.Decode.UnrecoverableValidationError validationError ->
                                        Just (Err [ validationError ])

                            Ok ( [], value ) ->
                                Just (Ok value)

                            Ok ( validationErrors, value ) ->
                                Just (Err validationErrors)
                   )

        Err _ ->
            Nothing


hasRestArgs : List UsageSpec -> Bool
hasRestArgs usageSpecs =
    List.any
        (\usageSpec ->
            case usageSpec of
                RestArgs _ ->
                    True

                _ ->
                    False
        )
        usageSpecs


expectedOperandCountOrFail : Command msg -> Command msg
expectedOperandCountOrFail ((Command ({ decoder, usageSpecs } as command)) as fullCommand) =
    Command
        { command
            | decoder =
                \({ operands } as stuff) ->
                    if
                        not (hasRestArgs usageSpecs)
                            && (operands |> List.length)
                            > (usageSpecs
                                |> List.filterMap
                                    (\option ->
                                        case option of
                                            Operand operand ->
                                                Just operand

                                            Option _ _ ->
                                                Nothing

                                            RestArgs _ ->
                                                Nothing
                                    )
                                |> List.length
                              )
                    then
                        Cli.Decode.MatchError "Wrong number of operands" |> Err
                    else
                        decoder stuff
        }


getDecoder :
    Command msg
    ->
        { operands : List String
        , options : List ParsedOption
        , usageSpecs : List UsageSpec
        }
    -> Result Cli.Decode.ProcessingError ( List Cli.Decode.ValidationError, msg )
getDecoder (Command { decoder }) =
    decoder


failIfUnexpectedOptions : Command msg -> Command msg
failIfUnexpectedOptions ((Command ({ decoder, usageSpecs } as command)) as fullCommand) =
    Command
        { command
            | decoder =
                \({ options } as flagsAndOperands) ->
                    let
                        unexpectedOptions =
                            List.filterMap
                                (\(Parser.ParsedOption optionName optionKind) ->
                                    if optionExistsNew usageSpecs optionName == Nothing then
                                        Just optionName
                                    else
                                        Nothing
                                )
                                options
                    in
                    if List.isEmpty unexpectedOptions then
                        decoder flagsAndOperands
                    else
                        Cli.Decode.MatchError ("Unexpected options " ++ toString unexpectedOptions) |> Err
        }


optionExistsNew : List UsageSpec -> String -> Maybe Option
optionExistsNew usageSpecs thisOptionName =
    usageSpecs
        |> List.filterMap
            (\usageSpec ->
                case usageSpec of
                    Option option occurences ->
                        option
                            |> Just

                    Operand _ ->
                        Nothing

                    RestArgs _ ->
                        Nothing
            )
        |> List.Extra.find (\option -> optionName option == thisOptionName)


type CommandBuilder msg
    = CommandBuilder
        { decoder : { usageSpecs : List UsageSpec, options : List ParsedOption, operands : List String } -> Result Cli.Decode.ProcessingError ( List Cli.Decode.ValidationError, msg )
        , usageSpecs : List UsageSpec
        , description : Maybe String
        , subCommand : Maybe String
        }


toCommand : CommandBuilder msg -> Command msg
toCommand (CommandBuilder record) =
    Command record


captureRestOperands : String -> CommandBuilder (List String -> msg) -> Command msg
captureRestOperands restOperandsDescription (CommandBuilder ({ usageSpecs, description, decoder } as record)) =
    Command
        { usageSpecs = usageSpecs ++ [ RestArgs restOperandsDescription ]
        , description = description
        , decoder =
            \({ operands } as stuff) ->
                let
                    restOperands =
                        operands
                            |> List.drop (operandCount usageSpecs)
                in
                resultMap (\fn -> fn restOperands) (decoder stuff)
        , subCommand = record.subCommand
        }


type Command msg
    = Command
        { decoder : { usageSpecs : List UsageSpec, options : List ParsedOption, operands : List String } -> Result Cli.Decode.ProcessingError ( List Cli.Decode.ValidationError, msg )
        , usageSpecs : List UsageSpec
        , description : Maybe String
        , subCommand : Maybe String
        }


build : msg -> CommandBuilder msg
build msgConstructor =
    CommandBuilder
        { usageSpecs = []
        , description = Nothing
        , decoder = \_ -> Ok ( [], msgConstructor )
        , subCommand = Nothing
        }


subCommand : String -> msg -> CommandBuilder msg
subCommand subCommandName msgConstructor =
    CommandBuilder
        { usageSpecs = []
        , description = Nothing
        , decoder = \_ -> Ok ( [], msgConstructor )
        , subCommand = Just subCommandName
        }


buildWithDoc : msg -> String -> CommandBuilder msg
buildWithDoc msgConstructor docString =
    CommandBuilder
        { usageSpecs = []
        , description = Just docString
        , decoder = \_ -> Ok ( [], msgConstructor )
        , subCommand = Nothing
        }


hardcoded : value -> CommandBuilder (value -> msg) -> CommandBuilder msg
hardcoded hardcodedValue (CommandBuilder ({ decoder } as command)) =
    CommandBuilder
        { command
            | decoder =
                \stuff -> resultMap (\fn -> fn hardcodedValue) (decoder stuff)
        }


resultMap : (a -> value) -> Result Cli.Decode.ProcessingError ( List Cli.Decode.ValidationError, a ) -> Result Cli.Decode.ProcessingError ( List Cli.Decode.ValidationError, value )
resultMap mapFunction result =
    result
        |> Result.map (\( validationErrors, value ) -> ( validationErrors, mapFunction value ))


expectFlag : String -> CommandBuilder msg -> CommandBuilder msg
expectFlag flagName (CommandBuilder ({ usageSpecs, decoder } as command)) =
    CommandBuilder
        { command
            | usageSpecs = usageSpecs ++ [ Option (Flag flagName) Required ]
            , decoder =
                \({ options } as stuff) ->
                    if
                        options
                            |> List.member (Parser.ParsedOption flagName Parser.Flag)
                    then
                        decoder stuff
                    else
                        Cli.Decode.MatchError ("Expect flag " ++ ("--" ++ flagName))
                            |> Err
        }


operandCount : List UsageSpec -> Int
operandCount usageSpecs =
    usageSpecs
        |> List.filterMap
            (\spec ->
                case spec of
                    Option _ _ ->
                        Nothing

                    Operand operandName ->
                        Just operandName

                    RestArgs _ ->
                        Nothing
            )
        |> List.length


keywordArgList : String -> CliSpec (List String) (List String)
keywordArgList flagName =
    CliSpec
        (\{ options } ->
            options
                |> List.filterMap
                    (\(Parser.ParsedOption optionName optionKind) ->
                        case ( optionName == flagName, optionKind ) of
                            ( False, _ ) ->
                                Nothing

                            ( True, Parser.OptionWithArg optionValue ) ->
                                Just optionValue

                            ( True, _ ) ->
                                -- TODO this should probably be an error
                                Nothing
                    )
                |> Ok
        )
        (Option (OptionWithStringArg flagName) ZeroOrMore)
        Cli.Decode.decoder


positionalArg : String -> CliSpec String String
positionalArg operandDescription =
    CliSpec
        (\{ usageSpecs, operands, operandsSoFar } ->
            case
                operands
                    |> List.Extra.getAt operandsSoFar
            of
                Just operandValue ->
                    Ok operandValue

                Nothing ->
                    Cli.Decode.MatchError ("Expect operand " ++ operandDescription ++ "at " ++ toString operandsSoFar ++ " but had operands " ++ toString operands) |> Err
        )
        (Operand operandDescription)
        Cli.Decode.decoder


withDefault : value -> CliSpec (Maybe value) (Maybe value) -> CliSpec (Maybe value) value
withDefault defaultValue (CliSpec dataGrabber usageSpec decoder) =
    CliSpec dataGrabber usageSpec (decoder |> Cli.Decode.map (Maybe.withDefault defaultValue))


optionalKeywordArg : String -> CliSpec (Maybe String) (Maybe String)
optionalKeywordArg optionName =
    CliSpec
        (\{ operands, options } ->
            case
                options
                    |> List.Extra.find
                        (\(Parser.ParsedOption thisOptionName optionKind) -> thisOptionName == optionName)
            of
                Nothing ->
                    Ok Nothing

                Just (Parser.ParsedOption _ (Parser.OptionWithArg optionArg)) ->
                    Ok (Just optionArg)

                _ ->
                    Cli.Decode.MatchError ("Expected option " ++ optionName ++ " to have arg but found none.") |> Err
        )
        (Option (OptionWithStringArg optionName) Optional)
        Cli.Decode.decoder


requiredKeywordArg : String -> CliSpec String String
requiredKeywordArg optionName =
    CliSpec
        (\{ operands, options } ->
            case
                options
                    |> List.Extra.find
                        (\(Parser.ParsedOption thisOptionName optionKind) -> thisOptionName == optionName)
            of
                Nothing ->
                    Cli.Decode.MatchError ("Expected to find option " ++ optionName ++ " but only found options " ++ toString options) |> Err

                Just (Parser.ParsedOption _ (Parser.OptionWithArg optionArg)) ->
                    Ok optionArg

                _ ->
                    Cli.Decode.MatchError ("Expected option " ++ optionName ++ " to have arg but found none.") |> Err
        )
        (Option (OptionWithStringArg optionName) Required)
        Cli.Decode.decoder


flag : String -> CliSpec Bool Bool
flag flagName =
    CliSpec
        (\{ options } ->
            if
                options
                    |> List.member (Parser.ParsedOption flagName Parser.Flag)
            then
                Ok True
            else
                Ok False
        )
        (Option (Flag flagName) Optional)
        Cli.Decode.decoder


mapNew : (toRaw -> toMapped) -> CliSpec from toRaw -> CliSpec from toMapped
mapNew mapFn (CliSpec dataGrabber usageSpec ((Cli.Decode.Decoder decodeFn) as decoder)) =
    CliSpec dataGrabber usageSpec (Cli.Decode.map mapFn decoder)


validate : (to -> ValidationResult) -> CliSpec from to -> CliSpec from to
validate validateFunction (CliSpec dataGrabber usageSpec (Cli.Decode.Decoder decodeFn)) =
    CliSpec dataGrabber
        usageSpec
        (Cli.Decode.Decoder
            (decodeFn
                >> (\result ->
                        Result.map
                            (\( validationErrors, value ) ->
                                case validateFunction value of
                                    Valid ->
                                        ( validationErrors, value )

                                    Invalid invalidReason ->
                                        ( validationErrors
                                            ++ [ { name = Cli.UsageSpec.name usageSpec
                                                 , invalidReason = invalidReason
                                                 , valueAsString = toString value
                                                 }
                                               ]
                                        , value
                                        )
                            )
                            result
                   )
            )
        )


validateIfPresent : (to -> ValidationResult) -> CliSpec from (Maybe to) -> CliSpec from (Maybe to)
validateIfPresent validateFunction cliSpec =
    validate
        (\maybeValue ->
            case maybeValue of
                Just value ->
                    validateFunction value

                Nothing ->
                    Valid
        )
        cliSpec


with : CliSpec from to -> CommandBuilder (to -> msg) -> CommandBuilder msg
with (CliSpec dataGrabber usageSpec (Cli.Decode.Decoder decodeFn)) ((CommandBuilder ({ decoder, usageSpecs } as command)) as fullCommand) =
    CommandBuilder
        { command
            | decoder =
                \optionsAndOperands ->
                    { options = optionsAndOperands.options
                    , operands = optionsAndOperands.operands
                    , usageSpecs = optionsAndOperands.usageSpecs
                    , operandsSoFar = operandCount usageSpecs
                    }
                        |> dataGrabber
                        |> Result.andThen decodeFn
                        |> Result.andThen
                            (\( validationErrors, fromValue ) ->
                                case
                                    resultMap (\fn -> fn fromValue)
                                        (decoder optionsAndOperands)
                                of
                                    Ok ( previousValidationErrors, thing ) ->
                                        Ok ( previousValidationErrors ++ validationErrors, thing )

                                    value ->
                                        value
                            )
            , usageSpecs = usageSpecs ++ [ usageSpec ]
        }


optionName : Option -> String
optionName option =
    case option of
        Flag flagName ->
            flagName

        OptionWithStringArg optionName ->
            optionName
