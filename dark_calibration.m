function darkData = dark_calibration(app)
%DARK_CALIBRATION  Measure the system's offsets with no light on the detector.
%
%   darkData = dark_calibration(app)
%
%   Every mixer channel sits on its own electrical offset and the DC
%   channel has a dark level.  Those have to come off the data before any
%   of it means anything, and they cannot be inferred from a sweep: the
%   phase fit would absorb some of the mixer offsets into its own o_i
%   term and the DC dark level would go straight into the modulation
%   depth, since
%
%       MoverB = mean(dVIF) * sqrt(1 + (tau*omega)^2) / (2 * mean(VDC))
%
%   divides by it.  A dark level left in there biases every lifetime the
%   rig reports.
%
%   WHY THIS IS A SEPARATE STEP
%
%   Closing the shutter in software is not the same as no light reaching
%   the detector.  The point of this measurement is the electronics as
%   they actually sit during an experiment - powered, warm, everything
%   running - with only the light removed.  That needs a person to block
%   the beam, so it is a deliberate step with its own button rather than
%   something folded silently into the sweep.
%
%   WHAT IT RECORDS
%
%   One second on the same channels, device and sample rate the
%   calibration and the acquisition will use, with both analog outputs at
%   0 V and the shutter closed.  From it:
%
%       offsetVIF   1x4 mean of ai0..ai3, the mixer offsets
%       offsetDC    scalar mean of ai4, the dark level
%
%   A second of data also says whether the front end is behaving, so the
%   same record is scored for stability: noise (sd), spread (peak to
%   peak), drift (slope across the second) and the largest periodic
%   component, which is what mains pickup looks like.  A channel that
%   fails any of those is reported - the offsets are still returned,
%   because a noisy channel's mean is still its best offset estimate, but
%   the number is worth less and the user should know.
%
%   Returns [] if the user cancels or the measurement fails.  Otherwise a
%   struct with offsetVIF, offsetDC, the raw trace, per-channel stats in
%   .stats, a .stable flag and .savedTo.
%
%   See also CALIBRATION, CALCULATE_PHASE_CALIBRATION, CALCULATE_TAU_S_G.

    DARK_SECONDS = 1.0;
    SETTLE_FRACTION = 0.1;    % of the record dropped at the start

    % Stability thresholds.  Heuristics for a +/-10 V input stage, chosen
    % to pass a quiet channel and catch an obviously sick one rather than
    % to certify anything.
    MAX_SD_MV      = 5;       % noise
    MAX_DRIFT_MVS  = 10;      % slope across the second
    MAX_P2P_SD     = 20;      % peak-to-peak as a multiple of sd (glitches)
    MAX_LINE_MV    = 2;       % largest periodic component

    darkData = [];

    dev = app.device;
    if isempty(dev) || ~isvalid(dev)
        uialert(app.fig, 'Select a valid device before measuring offsets.', ...
            'Dark Calibration Error');
        return;
    end

    rate = app.sampleRateSpinner.Value;
    nScans = max(16, round(DARK_SECONDS * rate));
    if ~isinf(dev.maxSweepScans())
        nScans = min(nScans, dev.maxSweepScans());
    end

    % The five FLIM channels, plus the monitor loopback when wired, so the
    % report covers everything the calibration will touch
    ids = dev.defaultInputChannels(5);
    if isfield(app, 'phaseMonitorColumn') && ~isempty(app.phaseMonitorColumn)
        ids{end+1} = strtrim(app.phaseMonitorEdit.Value);
    end
    nCh = numel(ids);
    inputChannels = struct('id', ids, 'type', repmat({'Analog'}, 1, nCh));

    % --- the instruction -------------------------------------------------
    % This is the one dialog in the application that asks the user to go
    % and do something physical, so it says what and why, briefly.
    msg = sprintf([ ...
        'Block the laser so no light reaches the detector, and check ' ...
        'the shutter is closed.\n\n' ...
        'Leave everything else powered and running - this measures the ' ...
        'electronics as they sit during an experiment.\n\n' ...
        'Then record %.0f s on %d channels at %g Hz.'], ...
        nScans / rate, nCh, rate);
    choice = uiconfirm(app.fig, msg, 'Dark Calibration', ...
        'Options', {'Record', 'Cancel'}, 'DefaultOption', 1, ...
        'CancelOption', 2, 'Icon', 'warning');
    if ~strcmp(choice, 'Record')
        return;
    end

    % --- record ----------------------------------------------------------
    % The same inversion the acquisition applies, applied here first, so
    % the offset is measured in the convention it will be subtracted in.
    % Measuring it the other way round puts the offset on with the wrong
    % sign and the error is twice the offset.
    invertIntensity = isfield(app, 'invertIntensityCheck') && ...
        app.invertIntensityCheck.Value;
    try
        [ai, nFilled] = dev.runClockedSweep(inputChannels, rate, ...
            zeros(nScans, 2), false, @(varargin) [], @() false);
        ai = flimir_apply_intensity_sign(ai, invertIntensity);
    catch ME
        uialert(app.fig, sprintf('Dark measurement failed:\n%s', ME.message), ...
            'Dark Calibration Error');
        return;
    end

    if nFilled < 16
        uialert(app.fig, sprintf(['The dark measurement returned only %d ' ...
            'scans, which is not enough to average.'], nFilled), ...
            'Dark Calibration Error');
        return;
    end

    % Drop the head: the outputs and shutter were commanded shut moments
    % ago and the input stage needs to settle
    settle = min(nFilled - 8, max(1, round(SETTLE_FRACTION * nFilled)));
    ai = ai(settle+1:nFilled, :);
    n = size(ai, 1);

    % --- score each channel ----------------------------------------------
    t = (0:n-1)' / rate;
    stats = repmat(struct('id', '', 'mean', NaN, 'sd', NaN, 'p2p', NaN, ...
        'driftMVPerS', NaN, 'lineHz', NaN, 'lineMV', NaN, ...
        'ok', false, 'note', ''), 1, nCh);

    for c = 1:nCh
        x = ai(:, c);
        good = isfinite(x);
        stats(c).id = ids{c};
        if nnz(good) < 8
            stats(c).note = 'no finite data';
            continue;
        end
        xg = x(good);
        stats(c).mean = mean(xg);
        stats(c).sd = std(xg);
        stats(c).p2p = range(xg);

        % Drift: slope of a straight line through the second
        p = polyfit(t(good), xg, 1);
        stats(c).driftMVPerS = 1000 * p(1);

        % Largest periodic component, with the trend removed so drift
        % does not masquerade as a low-frequency line
        [stats(c).lineHz, stats(c).lineMV] = dominantLine( ...
            xg - polyval(p, t(good)), rate);

        why = {};
        if 1000 * stats(c).sd > MAX_SD_MV
            why{end+1} = sprintf('noise %.1f mV', 1000 * stats(c).sd); %#ok<AGROW>
        end
        if abs(stats(c).driftMVPerS) > MAX_DRIFT_MVS
            why{end+1} = sprintf('drift %+.1f mV/s', stats(c).driftMVPerS); %#ok<AGROW>
        end
        if stats(c).sd > 0 && stats(c).p2p / stats(c).sd > MAX_P2P_SD
            why{end+1} = sprintf('spikes (p2p %.0fx sd)', ...
                stats(c).p2p / stats(c).sd); %#ok<AGROW>
        end
        if stats(c).lineMV > MAX_LINE_MV
            why{end+1} = sprintf('%.0f Hz pickup %.1f mV', ...
                stats(c).lineHz, stats(c).lineMV); %#ok<AGROW>
        end
        stats(c).ok = isempty(why);
        stats(c).note = strjoin(why, ', ');
    end

    % --- package ----------------------------------------------------------
    darkData = struct();
    darkData.kind         = 'dark';
    darkData.invertIntensity = invertIntensity;
    darkData.timestamp    = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
    darkData.device       = dev.DeviceID;
    darkData.backend      = feval([class(dev) '.backendName']);
    darkData.rate         = rate;
    darkData.seconds      = n / rate;
    darkData.channelIDs   = ids;
    darkData.ai           = ai;
    darkData.offsetVIF    = [stats(1:4).mean];
    darkData.offsetDC     = stats(5).mean;
    darkData.stats        = stats;
    darkData.stable       = all([stats.ok]);
    darkData.thresholds   = struct('maxSdMV', MAX_SD_MV, ...
        'maxDriftMVPerS', MAX_DRIFT_MVS, 'maxP2PoverSD', MAX_P2P_SD, ...
        'maxLineMV', MAX_LINE_MV);
    darkData.summary      = summariseDark(darkData);

    fprintf('\n%s\n', darkData.summary);

    showDarkMonitor(darkData);

    % --- archive it, always ------------------------------------------------
    % Same policy as the phase sweep: every measurement that produced data
    % is written to the data folder with a timestamp, adopted or not.
    darkData.savedTo = '';
    try
        darkData.savedTo = flimir_save_calibration( ...
            strtrim(app.saveDirEdit.Value), darkData, 'dark');
    catch ME
        warning('dark_calibration:saveFailed', ...
            'Could not archive the dark calibration: %s', ME.message);
    end
end

% =========================================================================

function [hz, mv] = dominantLine(x, rate)
% Biggest single frequency component, in mV, ignoring DC.  Mains pickup
% and switching supplies both show up here.

    hz = NaN;
    mv = 0;
    n = numel(x);
    if n < 16
        return;
    end
    % Hann window so a component that is not on a bin centre still reads
    % close to its true amplitude
    w = hann(n);
    X = fft(x(:) .* w);
    half = floor(n / 2);
    if half < 2
        return;
    end
    amp = 2 * abs(X(2:half+1)) / sum(w);   % single-sided amplitude
    f = (1:half)' * rate / n;
    [peak, k] = max(amp);
    hz = f(k);
    mv = 1000 * peak;
end

% =========================================================================

function s = summariseDark(d)
    lines = {sprintf('Dark calibration - %s on %s, %.2f s at %g Hz', ...
        d.backend, d.device, d.seconds, d.rate)};
    lines{end+1} = sprintf('%6s %10s %8s %8s %10s %12s   %s', ...
        'ch', 'offset mV', 'sd mV', 'p2p mV', 'drift mV/s', 'line', 'verdict');
    for c = 1:numel(d.stats)
        st = d.stats(c);
        if st.ok
            verdict = 'ok';
        else
            verdict = st.note;
        end
        lines{end+1} = sprintf('%6s %10.2f %8.2f %8.2f %10.1f %7.1fHz@%.1f   %s', ...
            st.id, 1000 * st.mean, 1000 * st.sd, 1000 * st.p2p, ...
            st.driftMVPerS, st.lineHz, st.lineMV, verdict); %#ok<AGROW>
    end
    if d.stable
        lines{end+1} = 'all channels stable';
    else
        bad = {d.stats(~[d.stats.ok]).id};
        lines{end+1} = sprintf(['UNSTABLE: %s - offsets are still usable ' ...
            'but trust them less'], strjoin(bad, ', '));
    end
    s = strjoin(lines, newline);
end

% =========================================================================

function showDarkMonitor(d)
% Traces and spectra, so "is it stable" can be answered by looking as
% well as by the numbers.  Reuses its own window the way the sweep
% monitor does rather than piling up figures.

    TAG = 'FLIMIR_DarkCalibrationMonitor';
    existing = findall(groot, 'Type', 'figure', 'Tag', TAG);
    if ~isempty(existing)
        fig = existing(1);
        delete(existing(2:end));
        clf(fig);
        figure(fig);
    else
        fig = figure('Name', 'Dark Calibration', 'NumberTitle', 'off', ...
            'Color', 'w', 'Position', [140 140 1000 620], 'Tag', TAG);
    end
    fig.Name = sprintf('Dark Calibration - %s', d.timestamp);

    nCh = numel(d.channelIDs);
    colors = lines(nCh);
    t = (0:size(d.ai, 1) - 1)' / d.rate;

    tl = tiledlayout(fig, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    if d.stable
        verdict = 'all channels stable';
    else
        verdict = sprintf('UNSTABLE: %s', strjoin( ...
            {d.stats(~[d.stats.ok]).id}, ', '));
    end
    title(tl, sprintf('Dark calibration - %s, %.2f s at %g Hz   |   %s', ...
        d.device, d.seconds, d.rate, verdict), 'FontWeight', 'bold');

    % Offsets removed, so the panel shows noise rather than five flat
    % lines at different heights
    ax1 = nexttile(tl);
    hold(ax1, 'on');
    for c = 1:nCh
        plot(ax1, t, 1000 * (d.ai(:, c) - d.stats(c).mean), ...
            'Color', colors(c, :), 'LineWidth', 0.5, ...
            'DisplayName', sprintf('%s (%+.1f mV)', d.channelIDs{c}, ...
            1000 * d.stats(c).mean));
    end
    hold(ax1, 'off');
    xlabel(ax1, 'Time (s)');
    ylabel(ax1, 'Deviation from offset (mV)');
    title(ax1, 'Dark traces, offset removed', 'FontWeight', 'normal');
    legend(ax1, 'show', 'Location', 'eastoutside', 'FontSize', 8);
    grid(ax1, 'on');
    xlim(ax1, [0 max(t)]);

    ax2 = nexttile(tl);
    hold(ax2, 'on');
    n = size(d.ai, 1);
    w = hann(n);
    half = floor(n / 2);
    f = (1:half)' * d.rate / n;
    for c = 1:nCh
        X = fft((d.ai(:, c) - d.stats(c).mean) .* w);
        amp = 2 * abs(X(2:half+1)) / sum(w);
        plot(ax2, f, 1000 * amp, 'Color', colors(c, :), 'LineWidth', 0.5);
    end
    hold(ax2, 'off');
    set(ax2, 'YScale', 'log');
    xlabel(ax2, 'Frequency (Hz)');
    ylabel(ax2, 'Amplitude (mV)');
    title(ax2, 'Amplitude spectrum - look for mains and switching lines', ...
        'FontWeight', 'normal');
    grid(ax2, 'on');
    xlim(ax2, [0 max(f)]);

    drawnow;
end
