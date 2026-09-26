function savedPath = flimir_save_calibration(target, calibrationData, kind)
%FLIMIR_SAVE_CALIBRATION  Write a calibration sweep to disk.
%
%   savedPath = flimir_save_calibration(target, calibrationData)
%
%   savedPath = flimir_save_calibration(target, calibrationData, kind)
%
%   target may be either
%     - a directory, in which case a timestamped file
%       <yyyy-mm-dd_HH-MM-SS>_<kind>_calibration.mat is created in it, or
%     - a full path ending in .mat, which is used as given.
%
%   kind is 'phase' (default) for a phase shifter sweep or 'dark' for a
%   shutter-closed offset measurement.  Both land in the same folder with
%   the same timestamping and fallback rules, so a session's calibration
%   history reads in order.
%
%   Every sweep that produced data is archived this way, whether or not
%   the user later chooses to use it, so a calibration is never lost just
%   because it was not adopted.  To guarantee that, the routine falls back
%   to a folder under userpath (and then to tempdir) if the requested
%   directory is missing or not writable.  The path actually used is
%   returned, so the caller can report it.
%
%   The file contains one variable, calibrationData, holding the whole
%   sweep: the commanded waveform, the raw recorded inputs, the per-ramp
%   segmentation and the fitted results including results.mixerCalibration.
%   Keeping the raw traces means a sweep can be reprocessed later with a
%   different analysis without going back to the bench; it also makes the
%   files large (roughly 40 bytes per scan per channel).
%
%   See also FLIMIR_LOAD_CALIBRATION, CALIBRATION.

    if nargin < 2 || isempty(calibrationData) || ~isstruct(calibrationData)
        error('flimir_save_calibration:badData', ...
            'calibrationData must be the struct produced by calibration.m');
    end

    if nargin < 3 || isempty(kind)
        kind = 'phase';
    end

    [targetDir, fileName] = splitTarget(target, kind);

    % Guarantee somewhere writable to land
    [targetDir, usedFallback] = resolveDirectory(targetDir);
    savedPath = fullfile(targetDir, fileName);

    calibrationData.savedAt = char(datetime('now', ...
        'Format', 'yyyy-MM-dd HH:mm:ss'));
    save(savedPath, 'calibrationData', '-v7.3');

    if usedFallback
        warning('flimir_save_calibration:fallbackDirectory', ...
            'Requested directory was unusable; calibration saved to %s', ...
            savedPath);
    end
end

% =========================================================================

function [targetDir, fileName] = splitTarget(target, kind)
    target = char(string(target));
    [pathPart, namePart, extPart] = fileparts(target);

    if strcmpi(extPart, '.mat')
        targetDir = pathPart;
        fileName = [namePart extPart];
        if isempty(targetDir)
            targetDir = pwd;
        end
    else
        targetDir = target;
        stamp = datestr(now, 'yyyy-mm-dd_HH-MM-SS'); %#ok<TNOW1,DATST>
        fileName = sprintf('%s_%s_calibration.mat', stamp, kind);
    end
end

% =========================================================================

function [useDir, usedFallback] = resolveDirectory(preferred)


    candidates = {preferred};
    up = userpath();
    if ~isempty(up)
        candidates{end+1} = fullfile(up, 'FLIMIR_calibrations');
    end
    candidates{end+1} = fullfile(tempdir, 'FLIMIR_calibrations');

    for i = 1:numel(candidates)
        candidate = candidates{i};
        if isempty(candidate)
            continue;
        end
        if ~isfolder(candidate)
            % Only create the fallbacks, never a directory the caller
            % merely mistyped
            if i == 1
                continue;
            end
            [ok, ~] = mkdir(candidate);
            if ~ok
                continue;
            end
        end
        if isWritable(candidate)
            useDir = candidate;
            usedFallback = (i > 1);
            return;
        end
    end

    error('flimir_save_calibration:noWritableDirectory', ...
        'Could not find anywhere writable to save the calibration.');
end

% =========================================================================

function tf = isWritable(folder)
    tf = false;
    probe = fullfile(folder, sprintf('.flimir_write_probe_%d', matlabProcessID));
    fid = fopen(probe, 'w');
    if fid == -1
        return;
    end
    fclose(fid);
    delete(probe);
    tf = true;
end
