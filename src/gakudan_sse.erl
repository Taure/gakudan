-module(gakudan_sse).
-moduledoc """
Byte-level Server-Sent Events parser shared by streaming LLM backends.

Incremental: concatenates `Chunk` onto the pending accumulator, splits
complete events on `\\n\\n`, decodes each event's `data:` line as JSON,
and returns `{[Event], NewPendingAcc}`. The trailing fragment that has
not yet seen its `\\n\\n` terminator stays in `NewPendingAcc` for the
next call.

Each event in the returned list is the decoded JSON map. The optional
`event:` line is ignored; backends that need the named event type
should read the `~"type"` key from the JSON payload (Anthropic does
this) or infer from the JSON shape (Gemini does this).

Events without a `data:` line (e.g. SSE comments / keepalives) are
skipped.
""".

-export([parse/2]).

-export_type([acc/0]).

-type acc() :: binary().

-doc """
Feed `Chunk` of raw SSE bytes into the parser. Returns the list of
fully-decoded JSON events and the new pending-byte accumulator.
""".
-spec parse(binary(), acc()) -> {[map()], acc()}.
parse(Chunk, Acc) ->
    Buf = <<Acc/binary, Chunk/binary>>,
    {Complete, Rest} = split_events(Buf),
    Events = [decode_event(E) || E <- Complete, has_data(E)],
    {Events, Rest}.

split_events(Buf) ->
    split_events(Buf, []).

split_events(Buf, Acc) ->
    case binary:split(Buf, ~"\n\n") of
        [Event, Rest] -> split_events(Rest, [Event | Acc]);
        [_Incomplete] -> {lists:reverse(Acc), Buf}
    end.

has_data(Event) ->
    binary:match(Event, ~"data: ") =/= nomatch.

decode_event(Event) ->
    Lines = binary:split(Event, ~"\n", [global]),
    case first_data_line(Lines) of
        {ok, Data} -> json:decode(Data);
        none -> #{}
    end.

first_data_line([]) ->
    none;
first_data_line([<<"data: ", Rest/binary>> | _]) ->
    {ok, Rest};
first_data_line([_ | T]) ->
    first_data_line(T).
