function calibrationData = calibration(app, mode, acquireFcn)
% CALIBRATION  Phase shifter calibration sweep with a live monitor.
%
%   calibrationData = calibration(app)
%
%   calibrationData = calibration(app, mode)
%
%   Drives the phase shifter analog output (ao1) through a series of
%   unidirectional ramps emitted as ONE continuous waveform, while recording
%   the five default analog inputs on the same sample clock.  Each ramp
%   climbs 0 -> 10 V over its duration, holds briefly at the top, then jumps
%   straight back to 0 for a rest.
%
%   mode is 'multiscale' (default) for 1, 3 and 10 s ramps, whose answers
%   are compared so rate dependence in the shifter shows up as disagreement
%   between them, or 'averaged' for ten 1 s ramps combined into one
%   calibration, where the scatter between them measures repeatability.
%
%   THE HOLD AT THE TOP OF EACH RAMP
%
%   The analysis low-passes each segment and discards 5/lpHz seconds at
%   each end, since a sample nearer than that to an edge has no real data
%   on one side of its filter kernel.  Without the hold that trim came out
%   of the top of the ramp - a fixed 0.1 s at the 50 Hz default, which is
%   10% of a 1 s ramp - so the calibration stopped a volt short of the top.
%   Holding at the peak gives the filter real data past the last ramp
%   sample, and both modes now calibrate the full 0 -> 10 V.
%
%   A monitor window opens before the sweep starts and fills in as the data
%   arrives, so the five channels can be watched live rather than only
%   inspected afterwards.  It carries a Stop button, and becomes the result
%   window when the sweep finishes.
%
%   The laser output (ao0) is held for the duration of the ramps at whatever
%   the Laser Power control is currently set to - that is 0 V, i.e. laser
%   off, unless a power has been dialled in - and the shutter is only opened
%   when that power is non-zero.  The waveform ends with both analog outputs
%   at 0 V, and the cleanup path forces them back to 0 and closes the
%   shutter even if the sweep errors or is stopped early.
%
%   calibrationData is a struct with fields:
%       time        - nScans x 1 time vector (s)
%       command     - nScans x 2 output scans, [laser, phaseShifter] (V)
%       ai          - nScans x 5 recorded analog inputs (V)
%       sweeps      - struct array, one per ramp: duration, startIdx
%                     (first ramp sample, 0 V), peakIdx (last ramp sample,
%                     at peakVolts) and endIdx (last sample of the hold)
%       rate        - sample rate actually used (Hz)
%       nScansFilled- how many scans were actually recorded (< nScans if
%                     the sweep was stopped early)
%       device      - device identifier reported by the backend
%       laserPowerV - laser output level held during the ramps
%       results     - output of calculate_phase_calibration
%
%   calibration(app, mode, acquireFcn) substitutes acquireFcn for the hardware
%   pass so the routine can be exercised with no DAQ board attached:
%       aiData = acquireFcn(rate, outputScans, onChunk)
%   where outputScans is nScans-by-2, aiData is nScans-by-5, and acquireFcn
%   is expected to call onChunk(aiBuffer, nFilled) as data accumulates so
%   the live path gets exercised too.

    PEAK_VOLTS      = 10;            % top of the ramp
    REST_SECONDS    = 0.5;           % 0 V hold before, between and after
    MAX_SCANS       = 2e6;           % caps memory for the whole sweep

    % Hold at the top of each ramp so the analysis has real data either
    % side of the peak and can keep the full 0 -> PEAK_VOLTS range.  It
    % has to cover the trim the low-pass forces, which is 5/lpSmoothingHz
    % seconds - 0.1 s at the 50 Hz default - with margin for a lower
    % cutoff.  See buildSweepWaveform.
    TOP_DWELL_SECONDS = 0.25;

    % Two ways to spend about the same 16 s of sweep.
    %
    %   multiscale  1, 3 and 10 s ramps.  The three answers are compared,
    %               so a phase shifter that behaves differently when
    %               driven fast shows up as disagreement between them.
    %               The slowest usable ramp becomes the calibration.
    %
    %   averaged    ten 1 s ramps, all fitted and then averaged.  No
    %               rate-dependence check - every ramp is the same speed
    %               - but ten independent estimates of the same quantity
    %               instead of one, so the scatter between them measures
    %               the repeatability directly and the mean is a lower
    %               variance answer.
    %
    % They answer different questions, which is why both are offered
    % rather than one replacing the other.
    MULTISCALE_DURATIONS = [1 3 10];
    AVERAGED_DURATIONS   = repmat(1, 1, 10); %#ok<RPMT1>

    if nargin < 2 || isempty(mode)
        mode = 'multiscale';
    end
    mode = validatestring(mode, {'multiscale', 'averaged'});
    switch mode
        case 'averaged'
            SWEEP_DURATIONS = AVERAGED_DURATIONS;
            modeLabel = 'Averaged';
            rampDescription = sprintf('%d x %g s ramps, averaged', ...
                numel(AVERAGED_DURATIONS), AVERAGED_DURATIONS(1));
        otherwise
            SWEEP_DURATIONS = MULTISCALE_DURATIONS;
            modeLabel = 'Multi-speed';
            rampDescription = sprintf('%s s ramps, compared', ...
                strjoin(string(MULTISCALE_DURATIONS), ', '));
    end

    calibrationData = [];
    dryRun = (nargin >= 3) && ~isempty(acquireFcn);

    % --- device -----------------------------------------------------------
    % All hardware access goes through app.device, a FlimirDaqDevice.  This
    % routine never names a vendor or a channel itself.
    dev = [];
    if dryRun
        deviceID = 'dry-run';
    else
        dev = app.device;
        if isempty(dev) || ~isvalid(dev)
            uialert(app.fig, 'Select a valid device before calibrating.', ...
                'Calibration Error');
            return;
        end
        if ~dev.supportsClockedSweep()
            uialert(app.fig, sprintf(['The %s backend cannot generate a ' ...
                'hardware-clocked sweep synchronised with its input, so ' ...
                'this calibration is not available for it.'], ...
                feval([class(dev) '.backendName'])), ...
                'Not Supported By This Backend');
            return;
        end
        deviceID = dev.DeviceID;
    end

    % --- sample rate, capped so the whole sweep stays in memory and
    %     fits whatever output buffer the device streams from ------------
    totalSeconds = sum(SWEEP_DURATIONS) ...
        + (REST_SECONDS + TOP_DWELL_SECONDS) * numel(SWEEP_DURATIONS) ...
        + 2 * REST_SECONDS;
    rate = app.sampleRateSpinner.Value;
    scanCap = MAX_SCANS;
    if ~isempty(dev)
        scanCap = min(scanCap, dev.maxSweepScans());
    end
    if rate * totalSeconds > scanCap
        rate = floor(scanCap / totalSeconds);
    end
    if rate < 20
        uialert(app.fig, sprintf(['This device can only emit %d scans in ' ...
            'one sweep, which over %.0f s leaves %g Hz - too coarse to ' ...
            'calibrate with.'], scanCap, totalSeconds, rate), ...
            'Sweep Too Coarse');
        return;
    end

    % --- build the continuous output waveform -----------------------------
    % Clip the ramp to what the board can actually put out.  A device that
    % cannot reach 10 V sweeps as far as it can and says so; silently
    % saturating at the top would look like a phase shifter that stops
    % responding.
    peakVolts = PEAK_VOLTS;
    clipped = false;
    if ~isempty(dev)
        outRange = dev.outputVoltageRange();
        if outRange(2) < peakVolts
            peakVolts = outRange(2);
            clipped = true;
        end
    end

    % Requested laser power, and the volts that actually express it.  A
    % controller can be wired so full scale means off; the power number
    % keeps its meaning and only the mapping changes.
    laserPowerV = app.laserPowerSpinner.Value;
    invertLaser = isfield(app, 'invertLaserCheck') && app.invertLaserCheck.Value;
    laserLimits = app.laserPowerSpinner.Limits;
    % The control already holds volts, so the drive level is simply it.
    % Only the resting level depends on the wiring: an inverted
    % attenuator is dark at full scale, a directly driven laser at zero.
    laserDriveV = laserPowerV;
    if invertLaser
        laserRestV = laserLimits(2);
    else
        laserRestV = 0;
    end

    [phaseColumn, sweeps] = buildSweepWaveform(SWEEP_DURATIONS, REST_SECONDS, ...
        peakVolts, rate, TOP_DWELL_SECONDS);

    % Tail on both channels so the board rests with the laser OFF when
    % the task stops - an NI analog output holds its last written sample,
    % and on an inverted controller a tail of zeros would leave it at
    % full power for as long as the board stayed idle.
    nTail = max(1, round(REST_SECONDS * rate));
    laserColumn = [repmat(laserDriveV, numel(phaseColumn), 1); ...
                   repmat(laserRestV, nTail, 1)];
    phaseColumn = [phaseColumn; zeros(nTail, 1)];
    outputScans = [laserColumn, phaseColumn];
    nScans = size(outputScans, 1);

    % Light reaches the sample when the drive differs from the dark
    % level - BELOW full scale on an inverted attenuator, above zero
    % on a direct laser. Testing > 0 would hold the shutter open
    % through a fully attenuated sweep.
    openShutter = abs(laserDriveV - laserRestV) > 1e-9;

    % --- offsets, from the Dark Calibration step --------------------------
    % Not measured here.  Blocking the beam is a physical act, so the
    % offsets come from the separate Dark Calibration the user runs with
    % the laser covered; closing the shutter in software would measure
    % something else and quietly call it dark.
    % Whichever way up the intensity channel is read, the sweep and the
    % dark offsets it uses have to agree.  A dark record taken under the
    % other convention is not just offset, it is offset the wrong way,
    % so it is refused rather than silently applied.
    invertIntensity = isfield(app, 'invertIntensityCheck') && ...
        app.invertIntensityCheck.Value;

    darkVIF = zeros(1, 4);
    darkDC = 0;
    darkNote = 'no dark calibration - offsets assumed zero';
    haveDark = isfield(app, 'darkCalibration') && ~isempty(app.darkCalibration);
    if haveDark && isfield(app.darkCalibration, 'invertIntensity') && ...
            app.darkCalibration.invertIntensity ~= invertIntensity
        haveDark = false;
        darkNote = ['dark calibration was taken with the opposite ' ...
                    'intensity inversion and was NOT used - re-run it'];
        warning('calibration:darkSignMismatch', '%s', darkNote);
    end
    if haveDark
        darkVIF = app.darkCalibration.offsetVIF;
        darkDC = app.darkCalibration.offsetDC;
        darkNote = sprintf('offsets from the dark calibration of %s%s', ...
            app.darkCalibration.timestamp, ...
            darkStabilityNote(app.darkCalibration));
    end

    % --- confirm before driving the hardware ------------------------------
    % One line of what is about to happen, plus a line per thing that is
    % actually wrong.  The monitor window shows the rest as it runs, and
    % Abort is a button away, so a wall of text here buys nothing.
    if ~dryRun
        msg = sprintf(['%s calibration: %s.\nSweep %s to %.1f V at ' ...
            '%g Hz, laser %.1f V. %.0f s.'], ...
            modeLabel, rampDescription, ...
            dev.phaseOutputChannel(), peakVolts, rate, laserPowerV, ...
            nScans / rate);
        icon = 'question';
        if ~openShutter
            msg = sprintf('%s\n\nLaser is 0 V - this will record darkness only.', msg);
            icon = 'warning';
        end
        if clipped
            msg = sprintf('%s\n\nThis device reaches only %.2f V, not %g V.', ...
                msg, peakVolts, PEAK_VOLTS);
            icon = 'warning';
        end
        if ~haveDark
            msg = sprintf(['%s\n\nNo dark calibration - offsets will be ' ...
                'assumed zero, which biases the modulation depth and ' ...
                'every lifetime.'], msg);
            icon = 'warning';
        end
        choice = uiconfirm(app.fig, msg, 'Run Phase Shifter Calibration', ...
            'Options', {'Run', 'Cancel'}, ...
            'DefaultOption', 1, 'CancelOption', 2, 'Icon', icon);
        if ~strcmp(choice, 'Run')
            return;
        end
    end

    % --- open the monitor, then run ---------------------------------------
    % The five FLIM channels, plus the phase monitor loopback when the
    % user has wired one.  Recording the phase voltage on the same clock
    % as the mixers is what lets the fit use a measured rather than an
    % assumed phase axis.
    nChannels = 5;
    phaseMonitorColumn = [];
    if isfield(app, 'phaseMonitorColumn') && ~isempty(app.phaseMonitorColumn)
        phaseMonitorColumn = 6;   % appended straight after the five
        nChannels = 6;
    end

    inputChannels = [];
    if ~dryRun
        ids = dev.defaultInputChannels(5);
        if ~isempty(phaseMonitorColumn)
            ids{end+1} = strtrim(app.phaseMonitorEdit.Value);
        end
        inputChannels = struct('id', ids, ...
            'type', repmat({'Analog'}, 1, nChannels));
    end

    % Rerun re-enters here with a fresh monitor; Abort leaves with nothing.
    while true
        monitor = createMonitor(outputScans, sweeps, rate, nChannels, ...
            peakVolts, deviceID, laserPowerV);
        onChunk = @(aiBuffer, nFilled) updateMonitor(monitor, aiBuffer, nFilled);
        stopFcn = @() monitorWantsOut(monitor.fig);

        try
            if dryRun
                aiData = acquireFcn(rate, outputScans, onChunk);
                nFilled = size(aiData, 1);
            else
                [aiData, nFilled] = dev.runClockedSweep(inputChannels, rate, ...
                    outputScans, openShutter, onChunk, stopFcn);
                aiData = flimir_apply_intensity_sign(aiData, invertIntensity);
            end
        catch ME
            markMonitorDone(monitor, sprintf('FAILED: %s', ME.message));
            uialert(app.fig, sprintf('Calibration failed:\n%s', ME.message), ...
                'Calibration Error');
            return;
        end

        if monitorRerunning(monitor.fig)
            continue;                    % discard and go round again
        end
        if monitorAborted(monitor.fig)
            markMonitorDone(monitor, 'ABORTED');
            return;                      % no analysis, no archive
        end
        break;
    end

    if nFilled < 1
        markMonitorDone(monitor, 'no data recorded');
        uialert(app.fig, 'The sweep returned no data.', 'Calibration Error');
        return;
    end

    % Trim to what was actually recorded, so a stopped sweep still analyses
    aiData = aiData(1:nFilled, :);

    % A sweep that clipped is the worst case for this routine: the fit
    % does not fail on a flat-topped sinusoid, it just returns a
    % confident wrong phase, and that calibration then silently biases
    % every lifetime taken with it.  Said here, before the numbers are
    % reported, so it cannot be mistaken for a good sweep.
    [clipped, clipMax, clipCh] = flimir_mixer_saturation(aiData);
    if clipped
        clipNames = strtrim(sprintf('ai%d ', clipCh - 1));
        warning('calibration:mixerSaturated', ...
            ['Mixer channel(s) %s reached %.2f V during the sweep. The ' ...
             'fit will still return a phase, but a clipped channel does ' ...
             'not carry one.'], clipNames, clipMax);
        uialert(app.fig, sprintf(['Mixer channel(s) %s reached %.2f V ' ...
            'during this sweep, at the input rail.\n\nThe fit still ' ...
            'produces numbers from a clipped channel, and they are ' ...
            'wrong. Increase the attenuator voltage and run the ' ...
            'calibration again.'], clipNames, clipMax), ...
            'Mixer Saturation (calibration)', 'Icon', 'warning');
    end
    outputScans = outputScans(1:nFilled, :);
    sweeps = clipSweeps(sweeps, nFilled);

    % --- package ----------------------------------------------------------
    calibrationData = struct();
    calibrationData.time         = (0:nFilled-1)' / rate;
    calibrationData.command      = outputScans;
    calibrationData.ai           = aiData;
    calibrationData.sweeps       = sweeps;
    calibrationData.rate         = rate;
    calibrationData.nScansFilled = nFilled;
    calibrationData.device       = deviceID;
    calibrationData.laserPowerV  = laserPowerV;
    calibrationData.peakVolts    = peakVolts;
    calibrationData.timestamp    = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
    calibrationData.phaseMonitorColumn = phaseMonitorColumn;
    calibrationData.offsetVIF    = darkVIF;
    calibrationData.offsetDC     = darkDC;
    calibrationData.darkNote     = darkNote;
    calibrationData.darkSource   = 'dark calibration step';
    calibrationData.invertIntensity = invertIntensity;
    calibrationData.mode         = mode;
    calibrationData.modeLabel    = modeLabel;

    % The sweep above is only the measurement; turning it into the numbers
    % that get stored and used is calculate_phase_calibration's job.  The
    % dark levels go in as options so every channel is de-offset before
    % the modulation depth - and therefore every lifetime - is computed.
    try
        calibrationData.results = calculate_phase_calibration(calibrationData, ...
            struct('offsetVIF', darkVIF, 'offsetDC', darkDC, ...
                   'combine', mode, 'invertIntensity', invertIntensity));
    catch ME
        calibrationData.results = struct('error', ME.message);
        uialert(app.fig, sprintf(['The sweep completed but the calibration ' ...
            'calculation failed:\n%s\n\nThe raw sweep is still returned ' ...
            'and saved.'], ME.message), 'Calibration Calculation Failed');
    end

    if nFilled < nScans
        doneNote = sprintf('stopped early - %.1f of %.1f s', ...
            nFilled / rate, nScans / rate);
    else
        doneNote = 'complete';
    end
    markMonitorDone(monitor, doneNote);

    % --- archive it, always ----------------------------------------------
    % Every sweep that produced data is written to the data folder with a
    % timestamp, alongside the acquisition files, whether or not it turns
    % out to be usable and whether or not the user adopts it.  Setup is a
    % prerequisite for calibrating precisely so that this directory is
    % known and valid; flimir_save_calibration only falls back elsewhere
    % if it has become unwritable since.  The path lands in
    % calibrationData.savedTo.
    calibrationData.savedTo = '';
    dataFolder = strtrim(app.saveDirEdit.Value);
    try
        savedTo = flimir_save_calibration(dataFolder, calibrationData);
        calibrationData.savedTo = savedTo;
        if isvalid(monitor.fig)
            try
                exportgraphics(monitor.fig, strrep(savedTo, '.mat', '.png'), ...
                    'Resolution', 150);
            catch
                % the figure is on screen regardless
            end
        end
    catch ME
        warning('calibration:saveFailed', ...
            'Could not archive the calibration: %s', ME.message);
        uialert(app.fig, sprintf(['The sweep finished but could not be ' ...
            'saved:\n%s\n\nIt is still returned in memory.'], ME.message), ...
            'Calibration Not Saved');
    end
end

% =========================================================================

function [phaseColumn, sweeps] = buildSweepWaveform(durations, restSeconds, ...
        peakVolts, rate, dwellSeconds)
% One continuous column: a rest, then each ramp, a hold at the top, and a
% rest.  Each ramp climbs 0 -> peakVolts and the following rest is the
% jump back down, so the command is unidirectional - no downward ramp.
%
% THE HOLD AT THE TOP
%
% The analysis low-passes each segment and then discards 5/lpHz seconds
% at each end, because a filtered sample within that distance of an edge
% has no real data on one side of its kernel.  With the segment ending at
% the peak, that trim came out of the top of the ramp - 0.1 s at the
% default 50 Hz cutoff, which is 10% of a 1 s ramp and cost the top volt
% of a 0 -> 10 V sweep.
%
% Holding at peakVolts past the end of the ramp gives the filter real
% data to work with there, so the trim lands in the hold and the whole
% 0 -> peakVolts range survives.  The hold is commanded, not analysed:
% the fit still stops at the peak sample.

    nRest = max(1, round(restSeconds * rate));
    nDwell = max(1, round(dwellSeconds * rate));
    nSweeps = numel(durations);
    sweeps = repmat(struct('duration', 0, 'startIdx', 0, 'peakIdx', 0, ...
        'endIdx', 0), 1, nSweeps);

    nPer = max(2, round(durations(:) * rate));
    phaseColumn = zeros(nRest + sum(nPer) + nSweeps * (nDwell + nRest), 1);

    pos = nRest;                       % leading rest is already zeros
    for k = 1:nSweeps
        n = nPer(k);
        % linspace so the last sample of the ramp sits exactly on peakVolts
        phaseColumn(pos + (1:n)) = linspace(0, peakVolts, n)';
        % then hold there before the step back to 0
        phaseColumn(pos + n + (1:nDwell)) = peakVolts;

        sweeps(k).duration = durations(k);
        sweeps(k).startIdx = pos + 1;
        sweeps(k).peakIdx  = pos + n;            % last sample of the ramp
        sweeps(k).endIdx   = pos + n + nDwell;   % last sample of the hold

        pos = pos + n + nDwell + nRest;   % trailing rest stays zero
    end
end

% =========================================================================

function sweeps = clipSweeps(sweeps, nFilled)
% Drop sweeps that never started and truncate one that was cut in half.

    keep = [sweeps.startIdx] <= nFilled;
    sweeps = sweeps(keep);
    for k = 1:numel(sweeps)
        % peakIdx is the end of the ramp and endIdx the end of the hold
        % after it, so both have to come back to what was recorded and
        % stay in that order
        sweeps(k).peakIdx = min(sweeps(k).peakIdx, nFilled);
        sweeps(k).endIdx = min(sweeps(k).endIdx, nFilled);
        sweeps(k).peakIdx = min(sweeps(k).peakIdx, sweeps(k).endIdx);
    end
end

% =========================================================================

function monitor = createMonitor(outputScans, sweeps, rate, nChannels, ...
        peakVolts, deviceID, laserPowerV)
% Command on top, the five inputs live in the middle, and one
% input-vs-command panel per ramp along the bottom.  The command is known
% in advance so it is drawn immediately; everything else fills in.

    MAX_DISPLAY_POINTS = 2000;
    MONITOR_TAG = 'FLIMIR_PhaseCalibrationMonitor';

    nScans = size(outputScans, 1);
    nSweeps = numel(sweeps);
    time = (0:nScans-1)' / rate;

    monitor = struct();
    monitor.time = time;
    monitor.command = outputScans;
    monitor.sweeps = sweeps;
    monitor.rate = rate;
    monitor.peakVolts = peakVolts;
    monitor.maxDisplayPoints = MAX_DISPLAY_POINTS;
    monitor.colors = lines(nChannels);

    % Reuse the monitor from the previous run rather than piling up a new
    % window every time Calibration is pressed.  clf keeps the figure's
    % size and screen position, so it comes back where the user left it.
    existing = findall(groot, 'Type', 'figure', 'Tag', MONITOR_TAG);
    if ~isempty(existing)
        monitor.fig = existing(1);
        delete(existing(2:end));        % in case any stragglers exist
        clf(monitor.fig);
        set(monitor.fig, 'Name', 'Phase Shifter Calibration - acquiring');
        figure(monitor.fig);             % bring it to the front
    else
        monitor.fig = figure('Name', 'Phase Shifter Calibration - acquiring', ...
            'NumberTitle', 'off', 'Color', 'w', 'Position', [80 80 1150 800], ...
            'Tag', MONITOR_TAG);
    end
    monitor.fig.UserData = struct('stopRequested', false, ...
                                  'rerunRequested', false);

    tl = tiledlayout(monitor.fig, 3, nSweeps, ...
        'TileSpacing', 'compact', 'Padding', 'compact');
    monitor.layout = tl;
    monitor.titleStem = sprintf('Phase shifter calibration - %s, %g Hz, laser %.1f V', ...
        deviceID, rate, laserPowerV);
    monitor.title = title(tl, sprintf('%s   |   acquiring 0.0 / %.1f s', ...
        monitor.titleStem, nScans / rate), 'FontWeight', 'bold');

    % --- row 1: both commanded outputs (fully known up front) ---
    ax1 = nexttile(tl, 1, [1 nSweeps]);
    di = decimateIdx(nScans, MAX_DISPLAY_POINTS);
    plot(ax1, time(di), outputScans(di, 2), 'k-', 'LineWidth', 1, ...
        'DisplayName', 'ao1 phase shifter');
    hold(ax1, 'on');
    plot(ax1, time(di), outputScans(di, 1), '-', 'Color', [0.85 0.33 0.10], ...
        'LineWidth', 1.25, 'DisplayName', sprintf('ao0 laser (%.1f V)', laserPowerV));
    % Shading, labels and the progress marker are decoration - keep them out
    % of the legend
    for k = 1:nSweeps
        xr = time([sweeps(k).startIdx, sweeps(k).endIdx]);
        patch(ax1, [xr(1) xr(2) xr(2) xr(1)], ...
            [0 0 peakVolts peakVolts], [0.2 0.4 0.8], ...
            'FaceAlpha', 0.07, 'EdgeColor', 'none', 'HandleVisibility', 'off');
        text(ax1, mean(xr), peakVolts * 1.04, sprintf('%g s', sweeps(k).duration), ...
            'HorizontalAlignment', 'center', 'FontSize', 8, 'Color', [0.2 0.4 0.8]);
    end
    monitor.nowLine = xline(ax1, 0, 'r-', 'LineWidth', 1.5, ...
        'HandleVisibility', 'off');
    hold(ax1, 'off');
    ylabel(ax1, 'Output (V)');
    title(ax1, 'Analog output command');
    xlim(ax1, [0 time(end)]);
    ylim(ax1, [-0.5 peakVolts * 1.15]);
    legend(ax1, 'show', 'Location', 'eastoutside', 'FontSize', 8);
    grid(ax1, 'on');
    monitor.commandAx = ax1;

    % --- row 2: the inputs, live ---
    ax2 = nexttile(tl, nSweeps + 1, [1 nSweeps]);
    hold(ax2, 'on');
    monitor.aiLines = gobjects(1, nChannels);
    for c = 1:nChannels
        monitor.aiLines(c) = plot(ax2, NaN, NaN, 'Color', monitor.colors(c, :), ...
            'LineWidth', 0.75, 'DisplayName', sprintf('ai%d', c - 1));
    end
    hold(ax2, 'off');
    xlabel(ax2, 'Time (s)');
    ylabel(ax2, 'Input (V)');
    title(ax2, 'Analog inputs (live)');
    xlim(ax2, [0 time(end)]);
    legend(ax2, 'show', 'Location', 'eastoutside', 'FontSize', 8);
    grid(ax2, 'on');
    monitor.aiAx = ax2;

    % --- row 3: response vs command, one panel per ramp ---
    monitor.sweepAx = gobjects(1, nSweeps);
    monitor.sweepLines = gobjects(nSweeps, nChannels);
    for k = 1:nSweeps
        axk = nexttile(tl, 2 * nSweeps + k);
        hold(axk, 'on');
        for c = 1:nChannels
            monitor.sweepLines(k, c) = plot(axk, NaN, NaN, '-', ...
                'Color', monitor.colors(c, :), 'LineWidth', 0.75);
        end
        hold(axk, 'off');
        xlabel(axk, 'ao1 (V)');
        if k == 1
            ylabel(axk, 'Input (V)');
        end
        title(axk, sprintf('%g s ramp', sweeps(k).duration), 'FontWeight', 'normal');
        xlim(axk, [0 peakVolts]);
        grid(axk, 'on');
        monitor.sweepAx(k) = axk;
    end

    % --- abort / rerun ---
    % Abort throws the run away; Rerun throws it away and starts again.
    % Both are only meaningful while a sweep is in flight, so they are
    % disabled once it finishes.
    monitor.abortBtn = uicontrol(monitor.fig, 'Style', 'pushbutton', ...
        'String', 'Abort', 'Units', 'normalized', ...
        'Position', [0.905 0.955 0.085 0.038], ...
        'BackgroundColor', [1 0.82 0.82], ...
        'Callback', @(~, ~) requestStop(monitor.fig));
    monitor.rerunBtn = uicontrol(monitor.fig, 'Style', 'pushbutton', ...
        'String', 'Rerun', 'Units', 'normalized', ...
        'Position', [0.812 0.955 0.085 0.038], ...
        'BackgroundColor', [0.88 0.92 1.00], ...
        'Callback', @(~, ~) requestRerun(monitor.fig));

    drawnow;
end

% =========================================================================

function requestStop(fig)
    setMonitorFlag(fig, 'stopRequested');
end

function requestRerun(fig)
    setMonitorFlag(fig, 'rerunRequested');
end

function setMonitorFlag(fig, name)
    if isvalid(fig)
        ud = fig.UserData;
        ud.(name) = true;
        fig.UserData = ud;
    end
end

function tf = monitorAborted(fig)
% A closed window means the same thing as pressing Abort.
    tf = ~isvalid(fig) || fig.UserData.stopRequested;
end

function tf = monitorRerunning(fig)
    tf = isvalid(fig) && fig.UserData.rerunRequested;
end

function tf = monitorWantsOut(fig)
% What the backends poll: either button ends the sweep in progress, and
% which one it was gets sorted out once control comes back.
    tf = monitorAborted(fig) || monitorRerunning(fig);
end

function closeMonitor(monitor)
    if isvalid(monitor.fig)
        delete(monitor.fig);
    end
end


% =========================================================================

function updateMonitor(monitor, aiBuffer, nFilled)
% Push whatever has arrived so far into the live axes.  Everything is
% decimated to a fixed number of points, so the cost per refresh does not
% grow as the sweep proceeds.

    if ~isvalid(monitor.fig) || nFilled < 2
        return;
    end

    di = decimateIdx(nFilled, monitor.maxDisplayPoints);
    t = monitor.time(di);
    for c = 1:numel(monitor.aiLines)
        set(monitor.aiLines(c), 'XData', t, 'YData', aiBuffer(di, c));
    end

    % Progress marker and title
    set(monitor.nowLine, 'Value', monitor.time(nFilled));
    monitor.title.String = sprintf('%s   |   acquiring %.1f / %.1f s', ...
        stripProgress(monitor.title.String), ...
        monitor.time(nFilled), monitor.time(end));

    % Per-ramp panels, for the portion of each ramp that has arrived
    for k = 1:numel(monitor.sweeps)
        s = monitor.sweeps(k);
        if s.startIdx > nFilled
            continue;
        end
        last = min(s.endIdx, nFilled);
        if last - s.startIdx < 2
            continue;
        end
        seg = s.startIdx:last;
        dk = seg(decimateIdx(numel(seg), monitor.maxDisplayPoints));
        cmd = monitor.command(dk, 2);
        for c = 1:size(monitor.sweepLines, 2)
            set(monitor.sweepLines(k, c), 'XData', cmd, 'YData', aiBuffer(dk, c));
        end
    end

    drawnow limitrate;
end

% =========================================================================

function markMonitorDone(monitor, note)
    if ~isvalid(monitor.fig)
        return;
    end
    monitor.fig.Name = sprintf('Phase Shifter Calibration - %s', note);
    monitor.title.String = sprintf('%s   |   %s', ...
        stripProgress(monitor.title.String), note);
    title(monitor.aiAx, 'Analog inputs');
    % Remove rather than disable: they have no job left, and leaving a
    % uicontrol on the figure makes exportgraphics warn about it
    for b = [monitor.abortBtn, monitor.rerunBtn]
        if isgraphics(b)
            delete(b);
        end
    end
    drawnow;
end

% =========================================================================

function s = stripProgress(s)
% Keep the fixed part of the title, drop any trailing status field.
    s = char(s);
    pos = strfind(s, '   |   ');
    if ~isempty(pos)
        s = s(1:pos(1)-1);
    end
end

% =========================================================================

function idx = decimateIdx(n, maxPoints)
    if n <= maxPoints
        idx = (1:n)';
    else
        idx = unique(round(linspace(1, n, maxPoints)))';
    end
end


% =========================================================================

function s = darkStabilityNote(darkData)
    if isfield(darkData, 'stable') && ~darkData.stable
        s = ' (flagged UNSTABLE)';
    else
        s = '';
    end
end
