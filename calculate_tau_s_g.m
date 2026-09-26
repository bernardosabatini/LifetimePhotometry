function [tau, s, g, detail] = calculate_tau_s_g(data, sampleRate, mixerCalibration, options)
% CALCULATE_TAU_S_G  Lifetime and phasor coordinates for one acquisition block.
%
%   [tau, s, g] = calculate_tau_s_g(data, sampleRate, mixerCalibration)
%   [tau, s, g, detail] = calculate_tau_s_g(..., options)
%
%   Translated from generateLifetimeEstimate.m.  Called once per
%   acquisition callback on the block of samples just read.
%
%   Channel mapping (old physData row -> column of data here):
%       physData(1:4,:) -> data(:,1:4) = ai0..ai3, the mixer channels
%                          VIF1..VIF4
%       physData(5,:)   -> data(:,5)   = ai4, the DC/intensity channel VDC
%
%   The dark offsets the old code subtracted at the call site
%   (mixerCalibration.offsetVIF / offsetDC) are subtracted here instead, so
%   the caller hands over raw acquired volts.
%
%   Inputs:
%       data             - [nSamples x 5] raw block, ai0..ai4 in columns
%       sampleRate       - acquisition sample rate (Hz)
%       mixerCalibration - struct from calculate_phase_calibration, i.e.
%                          results.mixerCalibration.  Required fields:
%                            phi_actual  4x1 channel phases (rad)
%                            max_VIF     1x4 calibration maxima
%                            min_VIF     1x4 calibration minima
%                            meanVDC     scalar calibration DC level
%                            tau_bar     calibration sample lifetime (s)
%                            omega       2*pi*laser modulation frequency
%                          Optional: offsetVIF (1x4), offsetDC, k_est, o_est
%       options          - optional struct:
%            lpCutoffHz   VDC smoothing cutoff (Hz)          [20]
%            robustMean   clip outliers before averaging     [true]
%            applyGainFit apply the fitted k_est/o_est       [false]
%
%   Outputs:
%       tau    - block lifetime (ns)
%       s      - block phasor S
%       g      - block phasor G
%       detail - struct of the per-sample vectors: lifetime, S, G, theta,
%                R, VIF_norm, VDC_LP
%
%   Without a usable calibration all three outputs are NaN: the phasor
%   angles are meaningless until the mixer phases are known.  Run
%   Calibration first.
%
%   robustMean defaults to true.  The original returned a plain mean of the
%   per-sample lifetimes but printed a 0.5-99.5 percentile clipped mean,
%   because lifetime = tan(theta) blows up for samples whose phasor angle
%   strays near +/-pi/2 and a single such sample wrecks the block average.
%   For a live chart the clipped value is the useful one.  Set
%   robustMean=false for the original's unclipped return.

    if nargin < 4
        options = struct();
    end
    opt = applyDefaults(options);

    tau = NaN;
    s = NaN;
    g = NaN;
    detail = struct('lifetime', [], 'S', [], 'G', [], 'theta', [], ...
        'R', [], 'VIF_norm', [], 'VDC_LP', []);

    if nargin < 3 || ~isCalibrationUsable(mixerCalibration)
        return;
    end
    if size(data, 2) < 5 || isempty(data)
        return;
    end

    cal = mixerCalibration;

    % --- offsets: what the old call site subtracted before calling --------
    offsetVIF = getOr(cal, 'offsetVIF', zeros(1, 4));
    offsetDC = getOr(cal, 'offsetDC', 0);

    VIF = data(:, 1:4)' - offsetVIF(:);     % 4 x N
    VDC = data(:, 5)' - offsetDC;           % 1 x N

    % --- VDC smoothing ----------------------------------------------------
    % Filtering VDC improves the S and G estimates; it does not affect the
    % lifetime, which comes from the ratio between channels.
    sd = sampleRate / opt.lpCutoffHz;
    VDC_LP = flimir_gaussian_lp(VDC, sd);

    % --- normalise --------------------------------------------------------
    VDCcal = cal.meanVDC;
    if VDCcal == 0 || ~isfinite(VDCcal)
        return;
    end
    VDC_LP_norm = VDC_LP / VDCcal;

    AmpVIF = (cal.max_VIF(:) - cal.min_VIF(:)) / 2;    % 4 x 1
    AmpVIF(AmpVIF == 0) = NaN;                          % dead channel -> NaN
    VIF_norm = VIF ./ AmpVIF;

    if opt.applyGainFit && isfield(cal, 'k_est') && isfield(cal, 'o_est')
        % The original left this commented out with a TODO, noting k ~= 1
        % and o ~= 0 so it made little difference.  Off by default.
        VIF_norm = (VIF_norm - cal.o_est(:)) ./ cal.k_est(:);
    end

    VIF_norm = VIF_norm ./ VDC_LP_norm;

    GoodMoverB = sqrt(1 + (cal.tau_bar * cal.omega)^2);
    VIF_norm = VIF_norm / GoodMoverB;

    % --- 1) instantaneous phasor, least squares ---------------------------
    [theta, R, S, G] = flimir_estimate_phasors(cal.phi_actual, VIF_norm);

    % --- 2) instantaneous lifetime from the phasor ------------------------
    lifetime = tan(theta) / cal.omega * 1e9;    % ns

    % --- 3) block averages ------------------------------------------------
    if opt.robustMean
        tau = clippedMean(lifetime);
    else
        tau = mean(lifetime);
    end
    s = mean(S);
    g = mean(G);

    detail.lifetime = lifetime;
    detail.S = S;
    detail.G = G;
    detail.theta = theta;
    detail.R = R;
    detail.VIF_norm = VIF_norm;
    detail.VDC_LP = VDC_LP;
end

% =========================================================================

function opt = applyDefaults(options)
    defaults = struct('lpCutoffHz', 20, 'robustMean', true, ...
        'applyGainFit', false);
    opt = defaults;
    fn = fieldnames(options);
    for i = 1:numel(fn)
        if isfield(defaults, fn{i})
            opt.(fn{i}) = options.(fn{i});
        end
    end
end

% =========================================================================

function tf = isCalibrationUsable(cal)
    tf = false;
    if isempty(cal) || ~isstruct(cal)
        return;
    end
    required = {'phi_actual', 'max_VIF', 'min_VIF', 'meanVDC', 'tau_bar', 'omega'};
    for i = 1:numel(required)
        if ~isfield(cal, required{i}) || isempty(cal.(required{i})) ...
                || any(~isfinite(cal.(required{i})(:)))
            return;
        end
    end
    tf = true;
end

% =========================================================================

function v = getOr(s, name, default)
    if isfield(s, name) && ~isempty(s.(name))
        v = s.(name);
    else
        v = default;
    end
end

% =========================================================================

function m = clippedMean(x)
% Drop the extreme 0.5% at each end before averaging, as the original did
% for its printed lifetime.  tan() near +/-pi/2 produces huge outliers that
% would otherwise dominate the block mean.
    x = x(isfinite(x));
    if isempty(x)
        m = NaN;
        return;
    end
    if numel(x) < 20
        m = median(x);
        return;
    end
    limits = prctile(x, [0.5 99.5]);
    kept = x(x > limits(1) & x < limits(2));
    if isempty(kept)
        m = median(x);
    else
        m = mean(kept);
    end
end
