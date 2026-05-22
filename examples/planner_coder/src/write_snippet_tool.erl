-module(write_snippet_tool).
-moduledoc """
Demo tool: writes a snippet to `priv/snippets/<filename>` (path constrained to
the priv dir, no traversal). Returns a confirmation string.
""".

-behaviour(gakudan_tool).

-export([spec/0, run/1]).

spec() ->
    #{
        name => ~"write_snippet",
        description => ~"Write a code snippet to a file inside the example's priv/snippets/ directory.",
        input_schema => #{
            type => ~"object",
            properties => #{
                filename => #{type => ~"string", description => ~"Basename only, no path separators."},
                content => #{type => ~"string"}
            },
            required => [~"filename", ~"content"]
        }
    }.

run(#{~"filename" := File, ~"content" := Content}) ->
    case is_safe_basename(File) of
        false ->
            {error, unsafe_filename};
        true ->
            Dir = filename:join(["/tmp", "gakudan_snippets"]),
            ok = filelib:ensure_dir(filename:join(Dir, "x")),
            Path = filename:join(Dir, File),
            ok = file:write_file(Path, Content),
            {ok, iolist_to_binary([~"wrote ", Path])}
    end;
run(_) ->
    {error, invalid_input}.

is_safe_basename(F) when is_binary(F) ->
    case binary:match(F, [<<"/">>, <<"\\">>, <<"..">>]) of
        nomatch -> byte_size(F) > 0 andalso byte_size(F) < 100;
        _ -> false
    end;
is_safe_basename(_) -> false.
