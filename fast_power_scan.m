function result = fast_power_scan(app)
%FAST_POWER_SCAN  Find the power fraction that fills the range without clipping.
%
%   result = fast_power_scan(app)
%
%   Drives the laser over a handful of short probes and returns the
%   largest power fraction whose mixer peaks stay under the set point.
%   Returns [] if the user cancels or nothing can be measured.
%
%   WHY A SEARCH RATHER THAN STEPPING
%
%   The automatic back-off steps 0.05 V at a time because it is
%   recovering from a problem during a run, where a small correction is
%   the right response.  Finding a working level from scratch that way is
%   the wrong tool: on a saturated rig it took sixteen full calibration
%   sweeps and five and a half minutes to walk from 3.50 V to 4.30 V.
%
%   Mixer amplitude rises monotonically with power, so the level can be
%   bisected instead.  Ten probes of 0.15 s bracket it to about a
%   thousandth of the range, and the whole thing takes a couple of
%   seconds.
%
%   WHAT IT AIMS FOR
%
%   The largest power whose peak stays below the set point - not the
%   largest that avoids clipping.  Headroom is the point: a level chosen
%   to sit just under the rail is back on it as soon as the sample
%   brightens.  The set point is the same one the back-off recovers to,
%   so the two agree about what "comfortable" means.
%
%   Each probe opens the shutter, so this is a deliberate action with a
%   confirmation, not something that runs on its own.
%
%   See also FLIMIR_MIXER_SATURATION, CALIBRATION.

    PROBE_SECONDS = 0.15;
    MAX_PROBES    = 10;
    SETTLE_FRAC   = 0.25;   % of each probe discarded while the light rises

    result = [];

    dev = app.device;
    if isempty(dev) || ~isvalid(dev) || ~app.isSetUp
        uialert(app.fig, 'Run Setup Acquisition first.', 'Setup Required');
        return;
    end
    if app.isRunning
        uialert(app.fig, ['Stop the acquisition before scanning for a ' ...
            'power level.'], 'Acquisition Running');
        return;
    end

    setpoint = app.backoffSetpointSpinner.Value;
    rate = app.sampleRateSpinner.Value;
    nScans = max(16, round(PROBE_SECONDS * rate));

    choice = uiconfirm(app.fig, sprintf([ ...
        'Find the power fraction whose mixer peaks stay under %.1f V.\n\n' ...
        'Up to %d probes of %.2f s with the shutter open, then the ' ...
        'result is applied.'], setpoint, MAX_PROBES, PROBE_SECONDS), ...
        'Fast Power Scan', 'Options', {'Scan', 'Cancel'}, ...
        'DefaultOption', 1, 'CancelOption', 2, 'Icon', 'question');
    if ~strcmp(choice, 'Scan')
        return;
    end

    ids = dev.defaultInputChannels(5);
    inputChannels = struct('id', ids, 'type', repmat({'Analog'}, 1, 5));

    minV = app.powerMinSpinner.Value;
    maxV = app.powerMaxSpinner.Value;
    startPower = app.laserPowerSpinner.Value;

    probes = struct('power', {}, 'volts', {}, 'peak', {}, 'saturated', {});
    cleanupFcn = onCleanup(@() restorePower(app, dev, startPower, minV, maxV));

    try
        % Full power first.  If the rig is comfortable there, there is
        % nothing to search for and the answer is 1.
        [peakFull, okFull] = probeAt(1);
        probes(end+1) = makeProbe(1, minV, maxV, peakFull, ~okFull);
        if isnan(peakFull)
            uialert(app.fig, ['The probe returned no usable data, so no ' ...
                'power level could be measured.'], 'Fast Power Scan');
            return;
        end
        if okFull
            best = 1;
        else
            % Bisect between dark (known good) and full (known too bright).
            lo = 0;      % highest power known to be under the set point
            hi = 1;      % lowest power known to be over it
            best = 0;
            for k = 2:MAX_PROBES
                mid = 0.5 * (lo + hi);
                [peak, ok] = probeAt(mid);
                probes(end+1) = makeProbe(mid, minV, maxV, peak, ~ok); %#ok<AGROW>
                if isnan(peak)
                    break;
                end
                if ok
                    lo = mid;
                    best = mid;
                else
                    hi = mid;
                end
                if (hi - lo) < 1e-3
                    break;
                end
            end
        end
    catch ME
        uialert(app.fig, sprintf('Fast power scan failed:\n%s', ME.message), ...
            'Fast Power Scan Error');
        return;
    end

    result = struct();
    result.timestamp = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
    result.setpointVolts = setpoint;
    result.probes = probes;
    result.bestPower = best;
    result.bestVolts = flimir_power_to_volts(best, minV, maxV);
    result.startPower = startPower;

    reportScan(result);

    % =====================================================================

    function [peak, ok] = probeAt(power)
        volts = flimir_power_to_volts(power, minV, maxV);
        dev.writeOutputs(volts, app.phaseShifterSpinner.Value, true);
        [ai, nFilled] = dev.runClockedSweep(inputChannels, rate, ...
            repmat([volts, app.phaseShifterSpinner.Value], nScans, 1), ...
            true, @(varargin) [], @() false);
        if nFilled < 8
            peak = NaN; ok = false;
            return;
        end
        % Drop the head: the light has only just been commanded up
        settle = min(nFilled - 4, max(1, round(SETTLE_FRAC * nFilled)));
        block = flimir_apply_intensity_sign(ai(settle+1:nFilled, :), ...
            isfield(app, 'invertIntensityCheck') && app.invertIntensityCheck.Value);
        [~, peak] = flimir_mixer_saturation(block);
        ok = peak < setpoint;
        fprintf('  probe power %.3f (%.2f V) -> peak %.2f V %s\n', ...
            power, volts, peak, ternaryText(ok, 'ok', 'too bright'));
        drawnow limitrate;
    end
end

% =========================================================================

function p = makeProbe(power, minV, maxV, peak, saturated)
    p = struct('power', power, ...
               'volts', flimir_power_to_volts(power, minV, maxV), ...
               'peak', peak, 'saturated', saturated);
end

function restorePower(app, dev, startPower, minV, maxV)
% Always leave the light where it was found, whatever happened.  A scan
% that threw partway through must not leave the shutter open at whatever
% probe it had reached.
    try
        dev.writeOutputs(flimir_power_to_volts(startPower, minV, maxV), ...
            app.phaseShifterSpinner.Value, false);
    catch
    end
end

function reportScan(r)
    fprintf('\n=== Fast power scan ===\n');
    fprintf('%8s %9s %9s  %s\n', 'power', 'volts', 'peak V', 'verdict');
    for k = 1:numel(r.probes)
        p = r.probes(k);
        fprintf('%8.3f %9.2f %9.2f  %s\n', p.power, p.volts, p.peak, ...
            ternaryText(~p.saturated, 'under set point', 'too bright'));
    end
    fprintf('set point %.1f V -> power fraction %.3f (%.2f V)\n\n', ...
        r.setpointVolts, r.bestPower, r.bestVolts);
end

function s = ternaryText(cond, a, b)
    if cond
        s = a;
    else
        s = b;
    end
end
