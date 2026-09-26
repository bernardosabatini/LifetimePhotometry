function lut = flimir_load_power_lut(filePath)
%FLIMIR_LOAD_POWER_LUT  Read a measured ao0-volts to output-power table.
%
%   lut = flimir_load_power_lut(filePath)
%
%   Reads a two column file of control voltage and output power in
%   microwatts, and returns a struct that flimir_estimate_power can
%   interpolate.  Accepts comma, tab or whitespace separated columns,
%   skips blank lines and anything starting with # or %, and tolerates a
%   header row of text.
%
%   Fields: volts, microwatts (both sorted by volts), nPoints,
%   voltRange, file, loadedAt, and stepVolts - the median spacing, which
%   is reported so an unexpectedly coarse or uneven table is visible.
%
%   WHAT IT DOES NOT DO
%
%   It does not fit a curve through the points and it does not
%   extrapolate.  See flimir_estimate_power for why.
%
%   See also FLIMIR_ESTIMATE_POWER.

    if nargin < 1 || isempty(filePath) || ~isfile(filePath)
        error('flimir_load_power_lut:noFile', ...
            'Power LUT file not found: %s', char(string(filePath)));
    end

    raw = readmatrixLoose(filePath);
    if isempty(raw) || size(raw, 2) < 2
        error('flimir_load_power_lut:badFormat', ...
            ['%s does not contain two columns of numbers. Expected ' ...
             'control voltage and output power in microwatts.'], filePath);
    end

    v = raw(:, 1);
    p = raw(:, 2);
    good = isfinite(v) & isfinite(p);
    v = v(good);
    p = p(good);
    if numel(v) < 2
        error('flimir_load_power_lut:tooFewPoints', ...
            'A LUT needs at least two usable rows; %s has %d.', ...
            filePath, numel(v));
    end

    [v, order] = sort(v);
    p = p(order);

    % Duplicate voltages would break the interpolation.  Averaging them
    % is the sane reading of a table measured twice at the same setting.
    [uv, ~, idx] = unique(v);
    if numel(uv) < numel(v)
        up = accumarray(idx, p, [], @mean);
        v = uv;
        p = up;
    end

    lut = struct();
    lut.volts = v(:);
    lut.microwatts = p(:);
    lut.nPoints = numel(v);
    lut.voltRange = [min(v), max(v)];
    lut.stepVolts = median(diff(v));
    lut.file = char(string(filePath));
    lut.loadedAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
end

% =========================================================================

function m = readmatrixLoose(filePath)
% Parse numbers out of a text file without assuming a delimiter or
% whether there is a header.  Written by hand rather than with
% readmatrix's options so the parsing rules are visible and the file
% stays toolbox free.

    fid = fopen(filePath, 'r');
    if fid == -1
        error('flimir_load_power_lut:unreadable', ...
            'Cannot open %s for reading.', filePath);
    end
    closeIt = onCleanup(@() fclose(fid));

    rows = {};
    while true
        line = fgetl(fid);
        if ~ischar(line)
            break;
        end
        line = strtrim(line);
        if isempty(line) || line(1) == '#' || line(1) == '%'
            continue;
        end
        parts = regexp(line, '[,\t; ]+', 'split');
        nums = str2double(parts);
        nums = nums(~isnan(nums));
        if numel(nums) >= 2
            rows{end+1} = nums(1:2); %#ok<AGROW>
        end
        % A line that did not parse is a header or a comment; skipping it
        % silently is right here, since the alternative is refusing a
        % perfectly good file because it was labelled
    end

    if isempty(rows)
        m = [];
    else
        m = cell2mat(rows(:));
    end
end
