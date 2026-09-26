function [mixerCalibration, calibrationData, summary] = flimir_load_calibration(filePath)
%FLIMIR_LOAD_CALIBRATION  Read a calibration sweep back from disk.
%
%   [mixerCalibration, calibrationData, summary] = flimir_load_calibration(filePath)
%
%   Returns:
%       mixerCalibration - the compact struct calculate_tau_s_g needs, or
%                          empty if the file holds no usable calibration
%                          (a sweep whose ramps all failed the sanity
%                          check is still a valid file, just not usable)
%       calibrationData  - the whole archived sweep
%       summary          - one line describing what was loaded, for the UI
%
%   Throws if the file is missing or is not a FLIMIR calibration file.  A
%   file that loads but contains no usable calibration is not an error:
%   mixerCalibration comes back empty and summary says why.
%
%   See also FLIMIR_SAVE_CALIBRATION, CALCULATE_TAU_S_G.

    mixerCalibration = [];

    filePath = char(string(filePath));
    if isempty(filePath) || ~isfile(filePath)
        error('flimir_load_calibration:notFound', ...
            'Calibration file not found:\n%s', filePath);
    end

    loaded = load(filePath);
    if ~isfield(loaded, 'calibrationData')
        error('flimir_load_calibration:notCalibration', ...
            ['This is not a FLIMIR calibration file (no calibrationData ' ...
             'variable):\n%s'], filePath);
    end
    calibrationData = loaded.calibrationData;

    if ~isstruct(calibrationData) || ~isfield(calibrationData, 'results')
        error('flimir_load_calibration:malformed', ...
            'Calibration file is missing its results:\n%s', filePath);
    end

    results = calibrationData.results;
    if isfield(results, 'mixerCalibration') && ~isempty(results.mixerCalibration)
        mixerCalibration = results.mixerCalibration;
    end

    summary = describe(filePath, calibrationData, mixerCalibration);
end

% =========================================================================

function summary = describe(filePath, calibrationData, mixerCalibration)
    [~, name, ext] = fileparts(filePath);

    if isfield(calibrationData, 'timestamp')
        when = calibrationData.timestamp;
    else
        when = 'unknown date';
    end
    if isfield(calibrationData, 'device')
        dev = calibrationData.device;
    else
        dev = 'unknown device';
    end

    if isempty(mixerCalibration)
        reason = 'no usable mixer calibration in this sweep';
        if isfield(calibrationData.results, 'agreement') && ...
                isfield(calibrationData.results.agreement, 'nSuspect')
            reason = sprintf(['no usable mixer calibration (%d ramps ' ...
                'failed the sanity check)'], ...
                calibrationData.results.agreement.nSuspect);
        end
        summary = sprintf('%s%s - %s, %s: %s', name, ext, when, dev, reason);
        return;
    end

    summary = sprintf('%s%s - %s, %s, from the %g s ramp at %g Hz', ...
        name, ext, when, dev, mixerCalibration.sourceRampSeconds, ...
        mixerCalibration.sourceRate);
end
