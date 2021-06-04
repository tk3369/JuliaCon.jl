is_schedule_json_available() = isfile(joinpath(CACHE_DIR, "schedule.json"))

"""
Get the conference schedule as a nested JSON object.
On first call, the schedule is downloaded from Pretalx and cached for further usage.
"""
function get_conference_schedule()
    isassigned(jcon) || update_schedule()
    return jcon[]
end

"""
    update_schedule(; verbose=false, ignore_timeout=false)

Explicitly trigger a schedule update according to the specified CACHE_MODE.
"""
function update_schedule(; verbose=false, notimeout=false)
    local file
    to = TimerOutput()
    verbose && @info "Cache mode: $CACHE_MODE"
    usecache = CACHE_MODE != :NEVER
    download_dir = usecache ? CACHE_DIR : mktempdir()

    if CACHE_MODE != :ALWAYS
        verbose && @info "Downloading $(default_json_url()) to $download_dir"
        if usecache && !isdir(CACHE_DIR)
            verbose && @info "Cache directory $CACHE_DIR created."
            mkpath(CACHE_DIR)
        end

        timeout =
            (usecache && is_schedule_json_available()) ? (!notimeout ? TIMEOUT : Inf) : Inf
        verbose && @info "Timeout set to $timeout seconds."

        try
            @timeit to "download" file = download(
                default_json_url(), joinpath(download_dir, "schedule.json.tmp"); timeout
            )
            file = mv(
                joinpath(download_dir, "schedule.json.tmp"),
                joinpath(download_dir, "schedule.json");
                force=true,
            )
        catch err
            if usecache
                @warn "Download failed or timed out. Falling back to cached schedule (might be stale). " *
                      "You can try forcing matters with JuliaCon.update_schedule(notimeout=true) or " *
                      "skipping the update altogether via JuliaCon.set_cachemode(:ALWAYS)."
                file = joinpath(CACHE_DIR, "schedule.json")
            else
                error(
                    "Download failed. Not using the cache due to CACHE_MODE = $CACHE_MODE."
                )
            end
        end
    else
        verbose && @info "Loading cached schedule.json"
        is_schedule_json_available() || error(
            "Can't find cached schedule.json. Not downloading due to CACHE_MODE = $CACHE_MODE.",
        )
        file = joinpath(CACHE_DIR, "schedule.json")
    end

    @timeit to "parse2json" data = JSON.parsefile(file)
    @timeit to "json2struct" jcon[] = json2struct(data["schedule"]["conference"])

    verbose && @info string("Timings:\n", to)
    return nothing
end

"""
Given a track (i.e. a fixed day), it finds the talks that are running now (it only compares times).
"""
function _find_current_talk_in_track(track::JuliaConTrack; now=default_now())
    for talk in track.talks
        start_time = Time(talk.start)
        dur = Time(talk.duration)
        end_time = start_time + Hour(dur) + Minute(dur)
        if start_time <= Time(now) <= end_time
            return talk
        end
    end
    return nothing
end

"""
Given a fixed day, it finds the talks in all tracks that are running now (it only compares times).

Returns a vector of tuples of the type `(track::String, talk::JuliaConTalk)`.
"""
function _find_current_talks_on_day(
    d::JuliaConDay; now=default_now()
)::Vector{Tuple{String,JuliaConTalk}}
    query_result = Vector{Tuple{String,JuliaConTalk}}(undef, length(d.tracks))
    for (i, track) in enumerate(d.tracks)
        query_result[i] = (track.name, _find_current_talk_in_track(track; now=now))
    end
    return filter(x -> !isnothing(x[2]), query_result)
end

function get_running_talks(; now=default_now())
    jcon = get_conference_schedule()

    dayidx = findfirst(d -> d.date == Date(now), jcon.days)
    if isnothing(dayidx)
        @info "There is no JuliaCon program today!"
        return nothing
    end

    d = jcon.days[dayidx]
    if !(d.start <= now <= d.stop)
        @info "There is no JuliaCon program now!"
        return nothing
    end

    current_talks = _find_current_talks_on_day(d; now=now)
    return current_talks
end

function _track2color(track::String)
    if track == "Red Track"
        return :red
    elseif track == "Green Track"
        return :green
    elseif track == "Purple Track"
        return :magenta
    else
        return :default
    end
end

function _print_running_talks(current_talks; now=default_now())
    !isnothing(current_talks) || return nothing
    # println()
    # println(Dates.format(default_now(), "HH:MM dd-mm-YYYY"))
    for (track, talk) in current_talks
        println()
        printstyled(track; bold=true, color=_track2color(track))
        println()
        println("\t", talk.title, " (", talk.type, ")")
        println("\t", "├─ ", speakers2str(talk.speaker))
        println("\t", "└─ ", talk.url)
    end
    println("\n")
    println("(Full schedule: https://pretalx.com/juliacon2021/schedule)")
    return nothing
end

function now(; now=default_now())
    current_talks = get_running_talks(; now=now)
    _print_running_talks(current_talks; now=now)
    return nothing
end

function get_today(; now=default_now())
    jcon = get_conference_schedule()

    dayidx = findfirst(d -> d.date == Date(now), jcon.days)
    if isnothing(dayidx)
        @info "There is no JuliaCon program today!"
        return nothing
    end

    schedule = [(track.name, track.talks) for track in jcon.days[dayidx].tracks]
    return schedule
end

speakers2str(speaker::Vector{String}) = join(speaker, ", ")

function today(; now=default_now(), track=nothing, terminal_links=TERMINAL_LINKS)
    track_schedules = get_today(; now=now)
    isnothing(track_schedules) && return nothing
    header = (["Time", "Title", "Type", "Speaker"],)
    header_crayon = crayon"dark_gray bold"
    border_crayon = crayon"dark_gray"
    h_times = Highlighter((data, i, j) -> j == 1, crayon"white bold")
    for (tr, talks) in track_schedules
        !isnothing(track) && tr != track && continue
        h_current = _get_current_talk_highlighter(talks; now=now)
        println()
        data = Matrix{Union{String, URLTextCell}}(undef, length(talks), 4)
        for (i, talk) in enumerate(talks)
            data[i, 1] = talk.start
            data[i, 2] = terminal_links ? URLTextCell(talk.title, talk.url) : talk.title
            data[i, 3] = abbrev(talk.type)
            data[i, 4] = speakers2str(talk.speaker)
        end
        pretty_table(
            data;
            title=tr,
            title_crayon=Crayon(; foreground=_track2color(tr), bold=true),
            header=header,
            header_crayon=header_crayon,
            border_crayon=border_crayon,
            highlighters=(h_times, h_current),
            tf=tf_unicode_rounded,
            alignment=[:c, :l, :c, :l],
        )
    end
    println()
    printstyled("Currently running talks are highlighted in ")
    printstyled("yellow"; color=:yellow)
    printstyled(".")
    println()
    println()
    print(abbrev(Talk), " = Talk, ")
    print(abbrev(LightningTalk), " = Lightning Talk, ")
    print(abbrev(SponsorTalk), " = Sponsor Talk, ")
    println(abbrev(Keynote), " = Keynote, ")
    print(abbrev(Workshop), " = Workshop, ")
    print(abbrev(Minisymposia), " = Minisymposia, ")
    println(abbrev(BoF), " = Birds of Feather")
    println()
    println("Check out https://pretalx.com/juliacon2021/schedule for more information.")
    return nothing
end

function _get_current_talk_highlighter(talks; now=default_now())
    for (i, talk) in enumerate(talks)
        start_time = Time(talk.start)
        dur = Time(talk.duration)
        end_time = start_time + Hour(dur) + Minute(dur)
        if start_time <= Time(now) <= end_time
            return Highlighter((data, m, n) -> m == i, crayon"yellow")
        end
    end
    return nothing
end
