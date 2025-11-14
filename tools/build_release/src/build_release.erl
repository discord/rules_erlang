-module(build_release).

-mode(compile).

-export([main/1]).

%% build_release - Generate Erlang release files (.rel, .script, .boot)
%% Usage: build_release <app_name> <app_version> <output_dir> [<release_name>] [<release_version>]
%%
%% app_version is used as a fallback if the version cannot be extracted from the .app file
%%
%% Reads dependency information from stdin as Erlang terms:
%% [{AppName::atom(), AppDir::string()}, ...]
%% Versions are extracted from .app files

-spec main([string()]) -> no_return().
main([AppName, AppVersion, OutputDir]) ->
    main([AppName, AppVersion, OutputDir, AppName, AppVersion]);
main([AppName, AppVersion, OutputDir, ReleaseName]) ->
    main([AppName, AppVersion, OutputDir, ReleaseName, AppVersion]);
main([AppName, AppVersion, OutputDir, ReleaseName, ReleaseVersion]) ->
    try
        %% Ensure SASL is available for systools
        ensure_sasl_loaded(),

        %% Read dependency information from stdin
        {ok, InputTerm} = io:read(""),

        %% Parse the input - either old format (list) or new format ({DepsInfo, ExtraApps})
        {DepsInfo, ExtraApps} = case InputTerm of
            {Deps, Extra} when is_list(Deps), is_list(Extra) ->
                {Deps, Extra};
            Deps when is_list(Deps) ->
                %% Old format - just deps list
                {Deps, []}
        end,

        %% Convert string app name to atom
        AppAtom = list_to_atom(AppName),
        ReleaseAtom = list_to_atom(ReleaseName),

        %% Generate the release
        generate_release(AppAtom, AppVersion, OutputDir, ReleaseAtom, ReleaseVersion, DepsInfo, ExtraApps),

        io:format("Successfully generated release files for ~s-~s~n", [ReleaseName, ReleaseVersion]),
        halt(0)
    catch
        error:{badmatch, {error, Reason}} ->
            io:format("Error: ~p~n", [Reason]),
            halt(1);
        Class:Reason:Stacktrace ->
            io:format("Unexpected error (~p): ~p~n~p~n", [Class, Reason, Stacktrace]),
            halt(1)
    end;
main(_) ->
    usage().

usage() ->
    io:format("Usage: build_release <app_name> <app_version> <output_dir> [<release_name>] [<release_version>]~n"),
    io:format("~n"),
    io:format("Generates Erlang release files (.rel, .script, .boot) using systools:make_script/2~n"),
    io:format("~n"),
    io:format("Arguments:~n"),
    io:format("  app_name        - Name of the main application~n"),
    io:format("  app_version     - Version of the main application (fallback if not in .app file)~n"),
    io:format("  output_dir      - Directory to write release files~n"),
    io:format("  release_name    - Name of the release (optional, defaults to app_name)~n"),
    io:format("  release_version - Version of the release (optional, defaults to app_version)~n"),
    io:format("~n"),
    io:format("Reads dependency information from stdin as Erlang terms.~n"),
    halt(1).

ensure_sasl_loaded() ->
    %% Ensure SASL is loaded for systools
    case code:ensure_loaded(systools) of
        {module, systools} ->
            ok;
        {error, _} ->
            %% Try to add SASL to the path
            case code:lib_dir(sasl) of
                {error, _} ->
                    throw({error, "SASL application not found. Cannot load systools module."});
                SaslDir ->
                    code:add_path(filename:join(SaslDir, "ebin")),
                    case code:ensure_loaded(systools) of
                        {module, systools} ->
                            ok;
                        {error, _} ->
                            throw({error, "Cannot load systools module even after adding SASL to path."})
                    end
            end
    end.

detect_required_otp_apps(DepsWithVersions) ->
    %% Get all app names we already have (user's apps)
    KnownApps = [AppName || {AppName, _, _} <- DepsWithVersions],
    io:format("DEBUG: Known apps: ~p~n", [KnownApps]),

    %% Collect all dependencies from .app files
    AllDeps = lists:foldl(fun({AppName, _Version, AppDir}, Acc) ->
        %% AppDir may already be pointing to ebin, or to the parent
        %% Try both paths
        AppFile1 = filename:join([AppDir, atom_to_list(AppName) ++ ".app"]),
        AppFile2 = filename:join([AppDir, "ebin", atom_to_list(AppName) ++ ".app"]),
        {AppFile, FileExists} = case {filelib:is_file(AppFile1), filelib:is_file(AppFile2)} of
            {true, _} -> {AppFile1, true};
            {false, true} -> {AppFile2, true};
            _ -> {AppFile1, false}
        end,
        io:format("DEBUG: Checking ~s for dependencies (exists: ~p)...~n", [AppFile, FileExists]),
        case file:consult(AppFile) of
            {ok, [{application, _, Props}]} ->
                %% Get both applications and included_applications
                Apps = proplists:get_value(applications, Props, []),
                IncludedApps = proplists:get_value(included_applications, Props, []),
                io:format("  Found deps: ~p~n", [Apps]),
                Apps ++ IncludedApps ++ Acc;
            Error ->
                %% If we can't read the .app file, continue
                io:format("  Could not read: ~p~n", [Error]),
                Acc
        end
    end, [], DepsWithVersions),

    %% Filter to only OTP apps (not in KnownApps, not kernel/stdlib which are always included)
    OtpApps = lists:filter(fun(App) ->
        not lists:member(App, KnownApps) andalso
        App =/= kernel andalso
        App =/= stdlib
    end, AllDeps),

    %% Remove duplicates and sort
    lists:usort(OtpApps).

%% Recursively discover all OTP app dependencies
discover_otp_app_deps(Apps) ->
    discover_otp_app_deps(Apps, [], []).

discover_otp_app_deps([], _Visited, Acc) ->
    %% Filter out kernel and stdlib since they're always included
    FilteredAcc = [A || A <- Acc, A =/= kernel, A =/= stdlib],
    lists:usort(FilteredAcc);
discover_otp_app_deps([App | Rest], Visited, Acc) ->
    case lists:member(App, Visited) of
        true ->
            %% Already visited, skip
            discover_otp_app_deps(Rest, Visited, Acc);
        false ->
            %% Try to find and read the app's .app file
            case code:lib_dir(App) of
                {error, bad_name} ->
                    %% App not found, skip it
                    discover_otp_app_deps(Rest, [App | Visited], Acc);
                Dir ->
                    AppFile = filename:join([Dir, "ebin", atom_to_list(App) ++ ".app"]),
                    case file:consult(AppFile) of
                        {ok, [{application, _, Props}]} ->
                            %% Get dependencies
                            Deps = proplists:get_value(applications, Props, []),
                            %% Filter out kernel and stdlib (always included)
                            FilteredDeps = [D || D <- Deps, D =/= kernel, D =/= stdlib],
                            %% Add new deps to the list to check
                            NewDeps = [D || D <- FilteredDeps, not lists:member(D, Visited)],
                            discover_otp_app_deps(Rest ++ NewDeps, [App | Visited], [App | Acc]);
                        _ ->
                            %% Can't read app file, just add the app itself
                            discover_otp_app_deps(Rest, [App | Visited], [App | Acc])
                    end
            end
    end.

extract_versions_with_fallback(DepsInfo, MainApp, MainAppFallback) ->
    lists:map(fun({AppName, AppDir}) ->
        %% Extract version from .app file for all apps
        Version = extract_app_version(AppName, AppDir),
        %% Debug suspicious versions
        case Version of
            "0.0.0" ->
                io:format("WARNING: Got version 0.0.0 for ~p from dir ~s~n", [AppName, AppDir]);
            _ -> ok
        end,
        %% Use fallback for main app if extraction failed
        FinalVersion = case {AppName, Version} of
            {MainApp, "0.0.0"} -> MainAppFallback;  % Use fallback if we got default
            _ -> Version
        end,
        {AppName, FinalVersion, AppDir}
    end, DepsInfo).

extract_app_version(AppName, AppDir) ->
    %% Try different locations for the .app file
    AppFile1 = filename:join([AppDir, "ebin", atom_to_list(AppName) ++ ".app"]),
    AppFile2 = filename:join(AppDir, atom_to_list(AppName) ++ ".app"),

    case file:consult(AppFile1) of
        {ok, [{application, _, Props}]} ->
            proplists:get_value(vsn, Props, "0.0.0");
        {error, _} ->
            case file:consult(AppFile2) of
                {ok, [{application, _, Props}]} ->
                    proplists:get_value(vsn, Props, "0.0.0");
                {error, _} ->
                    %% Check if AppDir itself is the .app file
                    case filelib:is_regular(AppDir) andalso filename:extension(AppDir) =:= ".app" of
                        true ->
                            case file:consult(AppDir) of
                                {ok, [{application, _, Props}]} ->
                                    proplists:get_value(vsn, Props, "0.0.0");
                                _ ->
                                    "0.0.0"
                            end;
                        false ->
                            "0.0.0"
                    end
            end
    end.

generate_release(AppName, AppVersionFallback, OutputDir, ReleaseName, ReleaseVersion, DepsInfo, ExtraApps) ->
    %% Ensure output directory exists
    ok = filelib:ensure_dir(filename:join(OutputDir, "dummy")),

    %% Get ERTS version
    ErtsVersion = erlang:system_info(version),

    %% Convert DepsInfo from [{Name, Dir}] to [{Name, Version, Dir}] by extracting versions
    %% Use AppVersionFallback if we can't extract the main app's version
    DepsWithVersions = extract_versions_with_fallback(DepsInfo, AppName, AppVersionFallback),

    %% Auto-detect required OTP applications from .app files
    RequiredOtpApps = detect_required_otp_apps(DepsWithVersions),
    io:format("DEBUG: Auto-detected OTP dependencies: ~p~n", [RequiredOtpApps]),

    %% Combine auto-detected with explicitly requested (ExtraApps)
    InitialOtpApps = lists:usort(RequiredOtpApps ++ ExtraApps),

    %% Recursively discover transitive OTP app dependencies
    AllRequiredOtpApps = discover_otp_app_deps(InitialOtpApps),
    io:format("DEBUG: Total OTP apps to include (with transitive deps): ~p~n", [AllRequiredOtpApps]),

    %% Build application list for the release
    %% Format: [{AppName, AppVersion} | {AppName, AppVersion, Type} | {AppName, AppVersion, IncludedApps}]
    Apps = build_app_list(AppName, DepsWithVersions, AllRequiredOtpApps),

    %% Create release specification
    RelSpec = {release,
               {atom_to_list(ReleaseName), ReleaseVersion},
               {erts, ErtsVersion},
               Apps},

    %% Write .rel file
    RelFile = filename:join(OutputDir, atom_to_list(ReleaseName) ++ ".rel"),
    ok = file:write_file(RelFile, io_lib:format("~p.~n", [RelSpec])),
    io:format("Generated ~s~n", [RelFile]),

    %% Write manifest file with EETF-encoded map of app_name -> version
    ManifestFile = filename:join(OutputDir, atom_to_list(ReleaseName) ++ ".manifest"),
    ManifestMap = maps:from_list([{Name, list_to_binary(Version)} || {Name, Version, _Dir} <- DepsWithVersions]),
    ok = file:write_file(ManifestFile, term_to_binary(ManifestMap)),
    io:format("Generated manifest ~s~n", [ManifestFile]),

    %% Set up paths for systools
    setup_code_paths(DepsWithVersions),

    %% Generate .script and .boot files using systools:make_script/2
    %% We need to pass the basename without extension and the directory
    BaseName = atom_to_list(ReleaseName),

    %% Options for make_script:
    %% - {outdir, Dir}: Output directory for .script and .boot files
    %% - {path, [Dir]}: Additional code paths
    %% - silent: Suppress warnings
    %% - no_module_tests: Skip module verification (faster)
    Options = [
        {outdir, OutputDir},
        {path, [AppDir || {_, _, AppDir} <- DepsWithVersions]},
        silent,
        no_module_tests
    ],

    %% Call systools:make_script/2
    %% This expects the .rel file to be in the current directory or one of the paths
    case systools:make_script(filename:join(OutputDir, BaseName), Options) of
        ok ->
            io:format("Generated ~s.script~n", [filename:join(OutputDir, BaseName)]),
            io:format("Generated ~s.boot~n", [filename:join(OutputDir, BaseName)]);
        error ->
            throw({error, "systools:make_script/2 failed"});
        {ok, _Module, Warnings} ->
            print_warnings(Warnings),
            io:format("Generated ~s.script~n", [filename:join(OutputDir, BaseName)]),
            io:format("Generated ~s.boot~n", [filename:join(OutputDir, BaseName)]);
        {error, _Module, Error} ->
            throw({error, {"systools:make_script/2 failed", Error}})
    end.

build_app_list(MainApp, DepsInfo, ExtraApps) ->
    %% Debug: print all available dependencies
    io:format("DEBUG: Available dependencies from build:~n"),
    lists:foreach(fun({Name, _Version, _Dir}) ->
        io:format("  - ~p~n", [Name])
    end, DepsInfo),

    io:format("DEBUG: Extra OTP apps requested: ~p~n", [ExtraApps]),

    %% Start with kernel and stdlib (required for all releases)
    %% These should be in DepsInfo but we ensure they're first
    KernelVersion = get_app_version(kernel, DepsInfo),
    StdlibVersion = get_app_version(stdlib, DepsInfo),

    %% Get main app version from DepsInfo
    MainAppVersion = get_app_version(MainApp, DepsInfo),
    io:format("DEBUG: Main app is ~p with version ~s~n", [MainApp, MainAppVersion]),

    %% Build the list starting with kernel and stdlib
    BaseApps = [
        {kernel, KernelVersion},
        {stdlib, StdlibVersion}
    ],

    %% Add requested OTP applications
    OtpApps = lists:filtermap(fun(AppAtom) ->
        %% First check if it's in DepsInfo
        case get_app_version(AppAtom, DepsInfo) of
            "0.0.0" ->
                %% Not in DepsInfo, try to get from system
                case code:lib_dir(AppAtom) of
                    {error, bad_name} ->
                        io:format("WARNING: Requested OTP app ~p not found~n", [AppAtom]),
                        false;
                    Dir ->
                        case file:consult(filename:join([Dir, "ebin", atom_to_list(AppAtom) ++ ".app"])) of
                            {ok, [{application, _, Props}]} ->
                                Vsn = proplists:get_value(vsn, Props, "0.0.0"),
                                io:format("  - Including OTP app ~p: ~s~n", [AppAtom, Vsn]),
                                {true, {AppAtom, Vsn}};
                            _ ->
                                io:format("WARNING: Could not read .app file for ~p~n", [AppAtom]),
                                false
                        end
                end;
            Version ->
                %% Found in DepsInfo
                io:format("  - Including OTP app ~p: ~s (from deps)~n", [AppAtom, Version]),
                {true, {AppAtom, Version}}
        end
    end, ExtraApps),

    %% Get list of OTP app names that were successfully added
    OtpAppNames = [Name || {Name, _} <- OtpApps],

    %% Add all other dependencies except kernel, stdlib, OTP apps, and the main app
    OtherDeps = [{AppName, Version} ||
                 {AppName, Version, _Dir} <- DepsInfo,
                 AppName =/= kernel,
                 AppName =/= stdlib,
                 not lists:member(AppName, OtpAppNames),  %% Use actual OTP apps included, not requested
                 AppName =/= MainApp],

    %% Debug: Show what's being added from DepsInfo
    io:format("DEBUG: Other deps from DepsInfo (after filtering):~n"),
    lists:foreach(fun({Name, Ver}) ->
        io:format("  - ~p: ~s~n", [Name, Ver])
    end, OtherDeps),

    %% Add main application last
    MainAppTuple = {MainApp, MainAppVersion},
    io:format("DEBUG: Adding main app tuple: ~p~n", [MainAppTuple]),
    AllApps = BaseApps ++ OtpApps ++ OtherDeps ++ [MainAppTuple],

    %% Debug: print what will be in the release
    io:format("DEBUG: Applications to be included in release:~n"),
    lists:foreach(fun({App, Ver}) ->
        io:format("  - ~p: ~s~n", [App, Ver])
    end, AllApps),

    AllApps.

get_app_version(AppName, DepsInfo) ->
    case lists:keyfind(AppName, 1, DepsInfo) of
        {AppName, Version, _Dir} ->
            Version;
        false ->
            %% Try to get from loaded applications
            case application:get_key(AppName, vsn) of
                {ok, Vsn} ->
                    Vsn;
                undefined ->
                    %% Use a default version if not found
                    "0.0.0"
            end
    end.

setup_code_paths(DepsInfo) ->
    %% Add all application directories to the code path
    lists:foreach(fun({_AppName, _Version, AppDir}) ->
        %% Add both the app directory and its ebin subdirectory
        code:add_patha(AppDir),
        EbinDir = filename:join(AppDir, "ebin"),
        case filelib:is_dir(EbinDir) of
            true -> code:add_patha(EbinDir);
            false -> ok
        end
    end, DepsInfo).

print_warnings([]) ->
    ok;
print_warnings(Warnings) ->
    io:format("Warnings:~n"),
    lists:foreach(fun(W) -> io:format("  ~p~n", [W]) end, Warnings).