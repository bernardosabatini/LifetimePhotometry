function results = calculate_phase_calibration(sweepData, options)
% CALCULATE_PHASE_CALIBRATION  Mixer phase calibration from a ramp sweep.
%
%   results = calculate_phase_calibration(sweepData)
%   results = calculate_phase_calibration(sweepData, options)
%
%   Translated from FLIPR_processCalibrationSweep / PCB_phaseEstimate.  The
%   old routine processed a single 30 s ramp; calibration.m now acquires
%   several ramps at different speeds in one recording, so every ramp is
%   processed independently and the answers are compared against each other.
%   Agreement across ramp speeds is the check that the phase shifter is not
%   rate dependent.
%
%   Channel mapping (old dataWaveN -> this acquisition):
%       dataWave0..3 -> ai0..ai3   the four mixer IF channels, VIF1..VIF4
%       dataWave4    -> ai4        the DC / intensity channel, VDC
%       dataWave5    -> V_phase, taken from the COMMANDED waveform.
%
%   If the phase shifter output is also looped back into a spare analog
%   input (the Phase Monitor option), that channel is not used as the
%   phase axis - it is compared against the command and scored, giving
%   gain, offset, output-to-input lag and worst residual in
%   results.monitorCheck.  The loopback is there to catch a timing or
%   level problem on the output path, so it is deliberately kept out of
%   the calibration itself: a check that silently changes the answer it
%   is checking is no check at all, and a wire that falls out would
%   corrupt the result instead of reporting itself.  On both the NI and
%   the T7 the lag measures one scan, so the commanded axis costs about
%   a millivolt of phase command over the slowest ramp.
%
%   Model fitted per ramp:
%
%       VIF_i = o_i + k_i * sin( phi_i + theta_V + phi_tau )
%
%       phi_i     fixed phase shift of LO channel i
%       theta_V   phase added by the shifter at control voltage V_phase
%       phi_tau   phase from the lifetime of the calibration sample,
%                 atan(tau_bar * omega), removed from theta at the end
%
%   Inputs:
%       sweepData - struct from calibration.m: time, command, ai, sweeps,
%                   rate, peakVolts
%       options   - optional struct, any subset of:
%           tauBar          lifetime of the calibration sample (s) [2.4e-9]
%           laserFreq       laser modulation frequency (Hz)        [50e6]
%           lpSmoothingHz   LP smoothing cutoff (Hz)               [50]
%           baselineSeconds baseline at V_phase = 0 kept ahead of
%                           each ramp (s)                          [0.5]
%           offsetVIF       1x4 dark offsets for ai0..ai3 (V)      [zeros]
%           offsetDC        scalar dark offset for ai4 (V)         [0]
%           maxIterations   gradient descent cap                   [2000]
%           verbose         print the per-ramp summary             [true]
%
%   offsetVIF/offsetDC come from a separate shutter-closed baseline
%   calibration in the old software.  With no offsets supplied they default
%   to zero, and the fit absorbs most of the residual into its own o_i term.
%
%   Output: results struct with a perSweep entry per ramp, the cross-ramp
%   comparison in results.agreement, and the phase shifter transfer curve
%   (controlVolts -> phaseRadians) taken from the slowest usable ramp.

    if nargin < 2
        options = struct();
    end
    opt = applyDefaults(options);
    monitorColumn = opt.phaseMonitorColumn;
    if isempty(monitorColumn) && isfield(sweepData, 'phaseMonitorColumn')
        monitorColumn = sweepData.phaseMonitorColumn;
    end

    omega = 2 * pi * opt.laserFreq;
    phiTau = atan(opt.tauBar * omega);

    rate = sweepData.rate;
    nSweeps = numel(sweepData.sweeps);

    % Gaussian SD in samples, and how much to cut off each end afterwards.
    % The old code used sd = fs/fpass and a fixed 1000 sample trim at
    % fs = 10 kHz / fpass = 50 Hz, which is exactly 5*sd - kept as a ratio
    % so it scales with whatever rate the sweep actually ran at.
    lpHz = min(opt.lpSmoothingHz, rate / 4);
    filterSD = max(1, round(rate / lpHz));
    filterEdgeSize = 5 * filterSD;

    results = struct();
    results.tauBar = opt.tauBar;
    results.laserFreq = opt.laserFreq;
    results.omega = omega;
    results.phiTau = phiTau;
    results.rate = rate;
    results.lpSmoothingHz = lpHz;
    results.filterSD = filterSD;
    results.filterEdgeSize = filterEdgeSize;
    results.offsetVIF = opt.offsetVIF;
    results.offsetDC = opt.offsetDC;
    results.method = 'FLIPR_processCalibrationSweep / PCB_phaseEstimate';
    results.combine = opt.combine;
    results.isPlaceholder = false;

    % --- the phase axis, and what the monitor says about it ------------
    % The fit always runs against the COMMANDED phase waveform.  The
    % loopback is a sanity check on the output-to-input path, not an
    % input to the calibration: making it load bearing means a wire that
    % falls out silently corrupts the answer, which is exactly backwards
    % for something whose job is to catch problems.  It buys little in
    % any case - the lag measures 1 scan on both the NI and the T7, which
    % over the slowest ramp is about a millivolt of phase command.
    %
    % So the monitor is compared against the command and reported: gain,
    % offset, lag and worst residual.  If it disagrees, that is said out
    % loud and the calibration proceeds regardless.
    results.phaseSource = 'commanded';
    results.outputLagSamples = NaN;
    results.outputLagMs = NaN;
    results.monitorCheck = [];
    opt.phaseMonitorColumn = [];        % never feeds the per-ramp fits
    if ~isempty(monitorColumn) && monitorColumn <= size(sweepData.ai, 2)
        results.monitorCheck = checkPhaseMonitor( ...
            sweepData.ai(:, monitorColumn), sweepData.command(:, 2), rate);
        results.outputLagSamples = results.monitorCheck.lagSamples;
        results.outputLagMs = results.monitorCheck.lagMs;
        if ~results.monitorCheck.tracking
            warning('calculate_phase_calibration:monitorNotTracking', ...
                'Phase monitor is not tracking the command: %s', ...
                results.monitorCheck.note);
        end
    end

    perSweep = struct([]);
    for k = 1:nSweeps
        s = processOneRamp(sweepData, sweepData.sweeps(k), opt, rate, ...
            filterSD, filterEdgeSize, omega, phiTau);
        if isempty(perSweep)
            perSweep = s;
        else
            perSweep(k) = s;
        end
    end
    results.perSweep = perSweep;

    % --- compare the ramps against each other --------------------------
    results.agreement = compareRamps(perSweep);

    % --- headline transfer curve, from the slowest ramp that worked -----
    usable = find([perSweep.ok] & ~[perSweep.suspect]);
    if isempty(usable)
        results.controlVolts = [];
        results.phaseRadians = [];
        results.phi_actual = nan(4, 1);
        results.referenceSweep = NaN;
        results.mixerCalibration = [];
    elseif strcmp(opt.combine, 'averaged')
        % Every ramp is the same speed, so there is no "best" one to
        % pick: they are repeat measurements of the same quantity and
        % the mean of them is the answer.  Phases are averaged as unit
        % vectors, since they wrap.
        ref = averageRamps(perSweep(usable));
        results.referenceSweep = ref.duration;
        results.controlVolts = ref.VPhase(:);
        results.phaseRadians = ref.thetaSweep(:);
        results.phi_actual = ref.phi_actual;
        results.mixerCalibration = buildMixerCalibration(ref, opt, omega, rate);
        results.mixerCalibration.combine = 'averaged';
        results.mixerCalibration.nRampsAveraged = numel(usable);
        results.mixerCalibration.sourceRampSeconds = ref.duration;
    else
        [~, slowest] = max([perSweep(usable).duration]);
        ref = perSweep(usable(slowest));
        results.referenceSweep = ref.duration;
        results.controlVolts = ref.VPhase(:);
        results.phaseRadians = ref.thetaSweep(:);
        results.phi_actual = ref.phi_actual;
        results.mixerCalibration = buildMixerCalibration(ref, opt, omega, rate);
        results.mixerCalibration.combine = 'multiscale';
        results.mixerCalibration.nRampsAveraged = 1;
    end

    if opt.verbose
        printSummary(results);
    end
end

% =========================================================================

function opt = applyDefaults(options)
    defaults = struct( ...
        'tauBar',          0, ... %2.4e-9, ...
        'laserFreq',       50e6, ...
        'lpSmoothingHz',   50, ...
        'baselineSeconds', 0.5, ...
        'offsetVIF',       zeros(1, 4), ...
        'offsetDC',        0, ...
        'invertIntensity', false, ...
        'combine',         'multiscale', ...
        'maxIterations',   2000, ...
        'unwrapTheta',     true, ...
        'phaseMonitorColumn', [], ...
        'verbose',         true);

    opt = defaults;
    fn = fieldnames(options);
    for i = 1:numel(fn)
        if isfield(defaults, fn{i})
            opt.(fn{i}) = options.(fn{i});
        else
            warning('calculate_phase_calibration:unknownOption', ...
                'Ignoring unknown option "%s".', fn{i});
        end
    end
    opt.offsetVIF = opt.offsetVIF(:)';
    if numel(opt.offsetVIF) ~= 4
        error('options.offsetVIF must have 4 elements, one per VIF channel.');
    end
end

% =========================================================================

function s = processOneRamp(sweepData, sweep, opt, rate, filterSD, ...
        filterEdgeSize, omega, phiTau)
% Everything FLIPR_processCalibrationSweep did to its single ramp, applied
% to one of ours.

    s = struct();
    s.duration = sweep.duration;
    s.ok = false;
    s.reason = '';

    % --- 1) carve out baseline + ramp ---------------------------------
    % The old code kept 0.5 s of V_phase = 0 baseline ahead of the ramp;
    % our inter-sweep rest supplies exactly that.
    nBaseline = round(opt.baselineSeconds * rate);
    startPoint = max(1, sweep.startIdx - nBaseline);
    nRows = size(sweepData.ai, 1);
    stopPoint = min(sweep.endIdx, nRows);
    s.baselineSamples = sweep.startIdx - startPoint;

    % Filter over baseline + ramp + hold, but fit only baseline + ramp.
    %
    % A filtered sample needs real data on both sides of its kernel, so
    % filterEdgeSize samples at each end of the segment are unusable.  At
    % the start that comes out of the baseline, which is there for it.  At
    % the end it used to come out of the top of the ramp, which cost the
    % top of the voltage range - 10% of a 1 s ramp.  The waveform now
    % holds at the peak afterwards, so the trim can come out of the hold
    % instead and the ramp survives to its last sample.
    %
    % peakIdx == endIdx in sweeps recorded before the hold existed; those
    % fall back to trimming the ramp, as they must.
    peakPoint = min(sweep.peakIdx, stopPoint);
    holdSamples = stopPoint - peakPoint;
    tailTrim = max(0, filterEdgeSize - holdSamples);

    keepLast = (peakPoint - startPoint + 1) - tailTrim;
    keep = (filterEdgeSize + 1):keepLast;
    keptLen = numel(keep);
    if keptLen < 10 * filterSD
        s.reason = sprintf(['ramp too short for the %d-sample filter edge ' ...
            'trim (%d samples left)'], filterEdgeSize, keptLen);
        s = padEmpty(s);
        return;
    end

    % --- 1) VIF1..4 (ai0..ai3) and VDC (ai4): smooth, trim, de-offset ---
    VIF = zeros(4, numel(keep));
    VIFraw = zeros(4, numel(keep));
    for ch = 1:4
        raw = sweepData.ai(startPoint:stopPoint, ch);
        smoothed = flimir_gaussian_lp(raw, filterSD);
        VIF(ch, :) = smoothed(keep) - opt.offsetVIF(ch);
        VIFraw(ch, :) = raw(keep)' - opt.offsetVIF(ch);
    end

    rawDC = sweepData.ai(startPoint:stopPoint, 5);
    smoothDC = flimir_gaussian_lp(rawDC, filterSD);
    s.VDC = smoothDC(keep) - opt.offsetDC;
    s.meanVDC = mean(rawDC(keep)) - opt.offsetDC;

    % --- 1b) V_phase ----------------------------------------------------
    % The commanded waveform, always.  It is exact, it is noiseless, and
    % it cannot come unplugged.  The monitor loopback checks it rather
    % than replacing it - see the phase axis block in the caller.
    if ~isempty(opt.phaseMonitorColumn) && ...
            opt.phaseMonitorColumn <= size(sweepData.ai, 2)
        % A measured axis carries noise, so it still wants smoothing
        rawPhase = sweepData.ai(startPoint:stopPoint, opt.phaseMonitorColumn);
        s.phaseSource = 'measured';
        smoothPhase = flimir_gaussian_lp(rawPhase, filterSD);
    else
        % The command is not measured, so there is nothing to filter out
        % of it.  Low-passing a straight line returns the same straight
        % line everywhere except at its corners, where it rounds them -
        % which at the peak pulls the axis below the voltage that was
        % actually commanded and shortens the calibrated range.  The
        % filter is zero-phase, so leaving the axis alone keeps it
        % aligned with the smoothed VIF.
        rawPhase = sweepData.command(startPoint:stopPoint, 2);
        s.phaseSource = 'commanded';
        smoothPhase = rawPhase(:)';
    end
    s.VPhase = smoothPhase(keep);

    % The lag is estimated once over the whole record (see the caller),
    % not here: within a single ramp the command is a straight line, and
    % cross-correlating a line against a shifted line has an almost flat
    % peak.  The sharp resets between ramps carry the timing.
    s.outputLagSamples = NaN;

    s.VIF = VIF;
    s.VIFraw = VIFraw;
    s.nSamples = numel(keep);
    s.voltRange = [min(s.VPhase), max(s.VPhase)];

    % --- 2) max / min of the offset-corrected VIF ----------------------
    [s.max_VIF, s.max_VIF_i] = max(VIF, [], 2);
    [s.min_VIF, s.min_VIF_i] = min(VIF, [], 2);
    s.max_VIF = s.max_VIF(:)';
    s.min_VIF = s.min_VIF(:)';
    s.max_VIF_i = s.max_VIF_i(:)';
    s.min_VIF_i = s.min_VIF_i(:)';

    % Volts of V_phase per sample, the old voltStep
    if s.nSamples > 1
        s.voltStep = (s.VPhase(end) - s.VPhase(1)) / (s.nSamples - 1);
    else
        s.voltStep = 0;
    end

    % --- 3) MoverB ------------------------------------------------------
    meanDeltaVIF = mean(s.max_VIF) - mean(s.min_VIF);
    s.MoverB = meanDeltaVIF * sqrt(1 + (opt.tauBar * omega)^2) / (2 * s.meanVDC);

    % --- 5) phase estimate ---------------------------------------------
    [phi_est, theta_est, k_est, o_est, rmsError] = pcbPhaseEstimate( ...
        VIF, s.max_VIF, s.min_VIF, phiTau, opt.maxIterations, opt.unwrapTheta);
    s.phi_est_raw = phi_est;
    s.theta_est = theta_est;
    s.k_est = k_est;
    s.o_est = o_est;
    s.rmsErrorMV = rmsError;

    % --- 6.1) clean up phi / theta -------------------------------------
    phi_est = simplifyAngles(phi_est);
    phi_deviation = simplifyAngles(phi_est - pi * (0:3)' / 2);
    mean_phi_deviation = mean(phi_deviation);
    phi_est = phi_est - mean_phi_deviation;
    theta_est = theta_est + mean_phi_deviation;

    % --- 6.2) reference everything to V_phase = 0 ----------------------
    % USE_0V_PHASE branch of the original: the shifter behaves best at 0 V,
    % so theta is measured relative to its value over the baseline.
    baselineCorrected = opt.baselineSeconds - 2 * filterEdgeSize / rate;
    nZero = round(baselineCorrected * rate);
    nZero = max(1, min(nZero, numel(theta_est)));
    theta_zero = mean(theta_est(1:nZero));

    s.VPhaseOffset = 0;
    s.PhaseOffsetIndex = 0;
    s.baselineCorrectedSec = baselineCorrected;
    s.thetaZeroSamples = nZero;
    s.theta_zero = theta_zero;
    s.phi_actual = phi_est + theta_zero;
    s.thetaSweep = theta_est - theta_zero;
    s.phi_est = phi_est;
    s.ok = true;

    % --- sanity: does the data actually look like four shifted sinusoids?
    % Without this, inputs with no modulation (nothing connected, shutter
    % closed, laser off) still produce a confident-looking set of angles.
    s.modulationDepth = s.max_VIF - s.min_VIF;
    s.suspect = false;
    s.suspectReason = '';
    if min(s.modulationDepth) < 0.01 * max(s.modulationDepth)
        s.suspect = true;
        s.suspectReason = 'at least one VIF channel shows no modulation';
    elseif s.rmsErrorMV > 100
        % RMS is on the per-channel normalised VIF (amplitude ~1) times
        % 1000, so 100 is a 10% residual against half-amplitude
        s.suspect = true;
        s.suspectReason = sprintf(['fit residual %.0f (10%% of half-' ...
            'amplitude is 100) - the model does not describe this data'], ...
            s.rmsErrorMV);
    end
end

% =========================================================================

function s = padEmpty(s)
% Fill in the fields a skipped ramp still needs so the struct array is
% uniform.
    blanks = {'VIF', 'VIFraw', 'VDC', 'VPhase', 'theta_est', 'thetaSweep'};
    for i = 1:numel(blanks)
        s.(blanks{i}) = [];
    end
    s.meanVDC = NaN;
    s.nSamples = 0;
    s.voltRange = [NaN NaN];
    s.max_VIF = nan(1, 4);   s.min_VIF = nan(1, 4);
    s.max_VIF_i = nan(1, 4); s.min_VIF_i = nan(1, 4);
    s.voltStep = NaN;        s.MoverB = NaN;
    s.phi_est_raw = nan(4, 1);
    s.k_est = nan(4, 1);     s.o_est = nan(4, 1);
    s.rmsErrorMV = NaN;
    s.VPhaseOffset = NaN;    s.PhaseOffsetIndex = NaN;
    s.baselineCorrectedSec = NaN;
    s.thetaZeroSamples = NaN;
    s.theta_zero = NaN;
    s.phi_actual = nan(4, 1);
    s.phi_est = nan(4, 1);
    s.phaseSource = 'none';
    s.outputLagSamples = NaN;
    s.modulationDepth = nan(1, 4);
    s.suspect = true;
    s.suspectReason = s.reason;
end

% =========================================================================

function [phi_est, theta_est, k_est, o_est, rmsErrorMV] = pcbPhaseEstimate( ...
        VIF, max_VIF, min_VIF, phiTau, maxIterations, unwrapTheta)
% PCB_phaseEstimate, minus the live figure it used to draw.  Gradient
% descent on phi (per channel), theta (per sample), and per-channel gain
% and offset, minimising rms(VIF_est - VIF).

    INCREMENT = -0.75;
    CONVERGENCE = 0.001;    % mV change in RMS between checks
    CHECK_EVERY = 50;

    % normalise each channel by its own half-amplitude
    VIFscale = (max_VIF(:) - min_VIF(:)) / 2;
    VIFscale(VIFscale == 0) = 1;
    VIF = VIF ./ VIFscale;

    phi_est = pi / 2 * (0:3)';
    k_est = ones(4, 1);
    o_est = zeros(4, 1);
    theta_est = flimir_estimate_phasors(phi_est, (VIF - o_est) ./ k_est);

    VIF_est = o_est + k_est .* sin(phi_est + theta_est);
    err = VIF - VIF_est;
    rms_error = rms(err(:)) * 1000;

    for loop = 1:maxIterations
        dVdTheta = cos(phi_est + theta_est);
        err = VIF - VIF_est;

        theta_est = theta_est - (INCREMENT * mean(err .* dVdTheta, 1));
        phi_est = phi_est - (INCREMENT * mean(err .* dVdTheta, 2));
        k_est = k_est + 0.05 * mean(abs(VIF) - abs(VIF_est), 2);
        o_est = o_est + 0.05 * mean(err, 2);
        VIF_est = o_est + k_est .* sin(phi_est + theta_est);

        if mod(loop, CHECK_EVERY) == 0
            new_rms_error = rms(err(:)) * 1000;
            converged = abs(new_rms_error - rms_error) < CONVERGENCE;
            rms_error = new_rms_error;
            if converged
                break;
            end
        end
    end

    rmsErrorMV = rms(err(:)) * 1000;

    % theta comes out of cart2pol wrapped to (-pi, pi].  The original code
    % left it that way, which is fine only while the shifter sweeps less
    % than a full turn over 0-10 V; beyond that the transfer curve gets a
    % 2*pi discontinuity.  Unwrapping is a no-op under half a turn per
    % sample, so it costs nothing in the cases the original handled.
    if unwrapTheta
        theta_est = unwrap(theta_est);
    end

    % take the calibration sample's own phase back out, and wrap phi to 0-2pi
    theta_est = theta_est - phiTau;
    phi_est = mod(phi_est + 4 * pi, 2 * pi);
end

% =========================================================================

function mc = buildMixerCalibration(ref, opt, omega, rate)
% Compact struct the per-block lifetime estimate needs at run time.
% Everything calculate_tau_s_g reads, and nothing else, so it can be
% stored and reloaded on its own.

    mc = struct();
    mc.phi_actual = ref.phi_actual;
    mc.max_VIF    = ref.max_VIF;
    mc.min_VIF    = ref.min_VIF;
    mc.meanVDC    = ref.meanVDC;
    mc.tau_bar    = opt.tauBar;
    mc.omega      = omega;
    mc.laserFreq  = opt.laserFreq;
    mc.offsetVIF  = opt.offsetVIF;
    mc.offsetDC   = opt.offsetDC;
    mc.invertIntensity = opt.invertIntensity;
    mc.k_est      = ref.k_est;
    mc.o_est      = ref.o_est;
    mc.MoverB     = ref.MoverB;
    mc.sourceRampSeconds = ref.duration;
    mc.sourceRate = rate;
    % How much of the shifter's range the fit actually saw.  A short ramp
    % loses proportionally more to the low-pass filter edge - the trim is
    % a fixed number of samples - so a 1 s ramp characterises less of the
    % curve than a 10 s one at the same rate.  Worth carrying, because it
    % is the main thing that differs between the two sweep modes.
    mc.controlVoltRange = ref.voltRange;
    mc.timestamp  = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
end

% =========================================================================

function avg = averageRamps(ps)
% Combine repeat ramps into one calibration, and record how much they
% disagreed while doing it.
%
% The scatter is as useful as the mean: it is a direct measurement of
% how repeatable the calibration is, taken under the same conditions in
% the same 16 seconds.  It comes back in the .spread fields.

    avg = ps(1);              % inherit shape, then overwrite
    n = numel(ps);
    avg.duration = ps(1).duration;
    avg.nRamps = n;

    % Phases wrap, so average them as unit vectors rather than numbers
    phi = [ps.phi_actual];                     % 4 x n
    avg.phi_actual = angle(mean(exp(1i * phi), 2));
    avg.phi_spreadDeg = rad2deg(circularSpread(phi, 2));

    % Everything else is an ordinary mean
    avg.max_VIF = mean(reshape([ps.max_VIF], 4, n), 2)';
    avg.min_VIF = mean(reshape([ps.min_VIF], 4, n), 2)';
    avg.k_est   = mean(reshape([ps.k_est], [], n), 2);
    avg.o_est   = mean(reshape([ps.o_est], [], n), 2);
    avg.meanVDC = mean([ps.meanVDC]);
    avg.MoverB  = mean([ps.MoverB]);

    avg.meanVDC_spread = std([ps.meanVDC]);
    avg.MoverB_spread  = std([ps.MoverB]);
    avg.rmsErrorMV     = mean([ps.rmsErrorMV]);

    % The transfer curve: each ramp covers the same control voltages but
    % not at the same samples, so interpolate onto a common grid before
    % averaging rather than assuming they line up.
    lo = max(cellfun(@(v) min(v), {ps.VPhase}));
    hi = min(cellfun(@(v) max(v), {ps.VPhase}));
    nGrid = round(mean([ps.nSamples]));
    if hi > lo && nGrid > 1
        grid = linspace(lo, hi, nGrid)';
        theta = nan(nGrid, n);
        for k = 1:n
            [v, iu] = unique(ps(k).VPhase(:), 'stable');
            th = ps(k).thetaSweep(:);
            theta(:, k) = interp1(v, th(iu), grid, 'linear', NaN);
        end
        avg.VPhase = grid;
        avg.thetaSweep = mean(theta, 2, 'omitnan');
        avg.thetaSweep_spread = std(theta, 0, 2, 'omitnan');
        avg.voltRange = [lo hi];
        avg.nSamples = nGrid;
    end
end

function s = circularSpread(phi, dim)
% Circular standard deviation, which is what "how much do these phases
% disagree" means once they can wrap.
    R = abs(mean(exp(1i * phi), dim));
    R = min(max(R, eps), 1);
    s = sqrt(-2 * log(R));
end

% =========================================================================

function chk = checkPhaseMonitor(measured, commanded, rate)
% Score the loopback against the command it is supposed to be carrying.
%
% Purely diagnostic: this answers "is the output arriving at the input
% when and at the level I asked for", which is what the wire was run to
% find out.  Nothing here feeds the calibration.

    chk = struct('tracking', false, 'gain', NaN, 'offset', NaN, ...
        'lagSamples', NaN, 'lagMs', NaN, 'maxResidual', NaN, ...
        'span', NaN, 'commandSpan', NaN, 'note', '');

    measured = measured(:);
    commanded = commanded(:);
    good = isfinite(measured) & isfinite(commanded);
    chk.span = range(measured(good));
    chk.commandSpan = range(commanded(good));

    if nnz(good) < 10 || chk.commandSpan <= 0
        chk.note = 'not enough finite data to compare';
        return;
    end

    % An unplugged input floats: it will not span anything like the ramp
    if chk.span < 0.5 * chk.commandSpan
        chk.note = sprintf(['spans only %.2f V against a %.2f V ' ...
            'command - looks unwired'], chk.span, chk.commandSpan);
        return;
    end

    chk.lagSamples = estimateLag(measured, commanded, max(1, round(0.25 * rate)));
    chk.lagMs = chk.lagSamples / rate * 1000;

    % Compare with the lag taken out, so a real delay is not charged
    % against the gain
    L = max(0, chk.lagSamples);
    n = numel(measured) - L;
    a = commanded(1:n);
    b = measured(L + (1:n));
    ok = isfinite(a) & isfinite(b);
    p = polyfit(a(ok), b(ok), 1);
    chk.gain = p(1);
    chk.offset = p(2);
    chk.maxResidual = max(abs(b(ok) - polyval(p, a(ok))));

    % 2% of gain and 1% of the ramp in residual is loose enough for an
    % honest wire and tight enough to catch a bad one
    chk.tracking = abs(chk.gain - 1) <= 0.02 && ...
        chk.maxResidual <= 0.01 * chk.commandSpan;
    if ~chk.tracking
        chk.note = sprintf(['gain %.4f and worst residual %.1f mV are ' ...
            'outside 2%% / %.1f mV'], chk.gain, 1000 * chk.maxResidual, ...
            10 * chk.commandSpan);
    end
end

% =========================================================================

function lag = estimateLag(measured, commanded, maxLag)
% Samples by which the measured signal trails the commanded one, by
% cross-correlation.  Positive means the input lags the output.  This is
% the old findOutputDelay, reduced to a diagnostic.
    measured = measured(:) - mean(measured);
    commanded = commanded(:) - mean(commanded);
    n = numel(measured);
    maxLag = min(maxLag, floor(n / 4));
    if n < 8 || maxLag < 1 || all(measured == 0) || all(commanded == 0)
        lag = NaN;
        return;
    end
    best = 0;
    bestScore = -inf;
    for k = -maxLag:maxLag
        if k >= 0
            a = measured(1+k:end);
            b = commanded(1:end-k);
        else
            a = measured(1:end+k);
            b = commanded(1-k:end);
        end
        % Normalise: a raw sum grows with overlap length and would always
        % peak at zero lag, where the overlap is longest
        denom = norm(a) * norm(b);
        if denom == 0
            continue;
        end
        score = (a' * b) / denom;
        if score > bestScore
            bestScore = score;
            best = k;
        end
    end
    lag = best;
end

% =========================================================================

function An = simplifyAngles(A)
% Wrap to -pi:pi
    An = mod(A + pi, pi * 2) - pi;
end

% =========================================================================

function agreement = compareRamps(perSweep)
% Do the different ramp speeds give the same answer?

    % Only ramps that both processed and passed the sanity check count
    % towards agreement - averaging in a garbage fit would hide it
    ok = [perSweep.ok] & ~[perSweep.suspect];
    agreement = struct();
    agreement.durations = [perSweep.duration];
    agreement.ok = ok;
    agreement.nUsable = sum(ok);
    agreement.nSuspect = sum([perSweep.suspect]);

    if agreement.nUsable < 1
        agreement.phi_actual = [];
        agreement.phi_mean = nan(4, 1);
        agreement.phi_spreadDeg = nan(4, 1);
        agreement.maxPhiSpreadDeg = NaN;
        agreement.MoverB = [];
        agreement.MoverBSpreadPct = NaN;
        agreement.consistent = false;
        return;
    end

    phi = [perSweep(ok).phi_actual];          % 4 x nUsable
    agreement.phi_actual = phi;
    % Average as unit vectors so the wrap point does not skew the mean
    agreement.phi_mean = atan2(mean(sin(phi), 2), mean(cos(phi), 2));
    dev = simplifyAngles(phi - agreement.phi_mean);
    agreement.phi_spreadDeg = (max(dev, [], 2) - min(dev, [], 2)) / pi * 180;
    agreement.maxPhiSpreadDeg = max(agreement.phi_spreadDeg);

    mb = [perSweep(ok).MoverB];
    agreement.MoverB = mb;
    if mean(mb) ~= 0
        agreement.MoverBSpreadPct = (max(mb) - min(mb)) / abs(mean(mb)) * 100;
    else
        agreement.MoverBSpreadPct = NaN;
    end

    agreement.rmsErrorMV = [perSweep(ok).rmsErrorMV];
    agreement.consistent = agreement.maxPhiSpreadDeg < 5;
end

% =========================================================================

function printSummary(results)
    ps = results.perSweep;
    fprintf('\n=== Phase shifter calibration (%s) ===\n', results.method);
    fprintf('tau_bar %.2f ns, laser %.1f MHz, phi_tau %.2f deg, LP %.0f Hz, %g Hz sampling\n', ...
        results.tauBar * 1e9, results.laserFreq / 1e6, ...
        results.phiTau / pi * 180, results.lpSmoothingHz, results.rate);
    fprintf('%7s %8s %9s %9s %10s   %s\n', 'ramp', 'samples', 'V range', ...
        'RMS(mV)', 'MoverB', 'phi_actual (deg)');
    for k = 1:numel(ps)
        if ~ps(k).ok
            fprintf('%6gs  SKIPPED - %s\n', ps(k).duration, ps(k).reason);
            continue;
        end
        fprintf('%6gs %8d %4.1f-%4.1f %9.2f %10.4f   %s\n', ...
            ps(k).duration, ps(k).nSamples, ps(k).voltRange(1), ...
            ps(k).voltRange(2), ps(k).rmsErrorMV, ps(k).MoverB, ...
            sprintf('%7.2f', ps(k).phi_actual / pi * 180));
        if ps(k).suspect
            fprintf('         ^ SUSPECT: %s\n', ps(k).suspectReason);
        end
    end

    % The axis is always the command; what the monitor thinks of it is a
    % separate line, because a failing loopback is worth seeing even
    % though it no longer changes the answer.
    fprintf('phase axis: commanded\n');
    if isempty(results.monitorCheck)
        fprintf('phase monitor: not wired\n');
    else
        m = results.monitorCheck;
        if m.tracking
            verdict = 'OK';
        else
            verdict = 'NOT TRACKING';
        end
        fprintf(['phase monitor: %s - measured = %.4f x commanded ' ...
            '%+.4f V, lag %d samples (%.2f ms), worst residual %.1f mV\n'], ...
            verdict, m.gain, m.offset, m.lagSamples, m.lagMs, ...
            1000 * m.maxResidual);
        if ~m.tracking
            fprintf('               %s\n', m.note);
        end
    end

    a = results.agreement;
    if a.nSuspect > 0
        fprintf('---\n%d of %d ramps failed the sanity check and are excluded.\n', ...
            a.nSuspect, numel(ps));
        if a.nUsable == 0
            fprintf(['No usable ramp. Check that the four mixer channels ' ...
                'are connected and modulating.\n']);
            printMixerCalibration(results.mixerCalibration);
            fprintf('\n');
            return;
        end
    end
    if a.nUsable >= 2
        fprintf('---\nacross %d ramps: max phi spread %.2f deg, MoverB spread %.1f%%\n', ...
            a.nUsable, a.maxPhiSpreadDeg, a.MoverBSpreadPct);
        fprintf('per-channel phi spread (deg): %s\n', ...
            sprintf('%.2f ', a.phi_spreadDeg));
        if a.consistent
            fprintf('ramps AGREE (phi spread under 5 deg)\n');
        else
            fprintf('ramps DISAGREE - the shifter looks rate dependent\n');
        end
    end

    printMixerCalibration(results.mixerCalibration);
    fprintf('\n');
end

% =========================================================================

function printMixerCalibration(mc)
% The numbers that actually leave this function and get used.
%
% Printed in full after every run so two calibrations can be put side by
% side - different modes, or the same mode hours apart - and compared by
% eye without loading the .mat files.

    fprintf(['\n================ CALIBRATION VALUES ' ...
        '================\n']);
    if isempty(mc)
        fprintf('  none - no usable ramp, nothing was produced\n');
        fprintf(['=================================================' ...
            '=======\n']);
        return;
    end

    if isfield(mc, 'combine') && strcmp(mc.combine, 'averaged')
        fprintf('  source     : %d x %g s ramps, averaged\n', ...
            mc.nRampsAveraged, mc.sourceRampSeconds);
    else
        fprintf('  source     : %g s ramp\n', mc.sourceRampSeconds);
    end
    fprintf('  taken      : %s at %g Hz\n', mc.timestamp, mc.sourceRate);
    if isfield(mc, 'controlVoltRange')
        fprintf('  V covered  : %.2f to %.2f V of the shifter range\n', ...
            mc.controlVoltRange(1), mc.controlVoltRange(2));
    end
    fprintf('  tau_bar    : %.3f ns   laser %.1f MHz\n', ...
        1e9 * mc.tau_bar, mc.laserFreq / 1e6);
    fprintf('\n');
    fprintf('  phi_actual : %s  deg\n', ...
        sprintf('%10.4f', rad2deg(mc.phi_actual)));
    fprintf('  max_VIF    : %s  V\n', sprintf('%10.5f', mc.max_VIF));
    fprintf('  min_VIF    : %s  V\n', sprintf('%10.5f', mc.min_VIF));
    fprintf('  k_est      : %s  V\n', sprintf('%10.5f', mc.k_est));
    fprintf('  o_est      : %s  V\n', sprintf('%10.5f', mc.o_est));
    fprintf('  offsetVIF  : %s  mV\n', sprintf('%10.3f', 1000 * mc.offsetVIF));
    fprintf('\n');
    fprintf('  meanVDC    : %.6f V      offsetDC : %.3f mV\n', ...
        mc.meanVDC, 1000 * mc.offsetDC);
    fprintf('  MoverB     : %.6f\n', mc.MoverB);
    fprintf(['========================================================' ...
        '\n']);
end
