function [saturated, maxAbs, channels] = flimir_mixer_saturation(data, railVolts)
%FLIMIR_MIXER_SATURATION  Are any mixer channels pinned at the input rail?
%
%   [saturated, maxAbs, channels] = flimir_mixer_saturation(data)
%   [...] = flimir_mixer_saturation(data, railVolts)
%
%   data is nSamples-by-nChannels with the four mixer channels in columns
%   1 to 4.  Returns whether any of them touched the rail, the largest
%   absolute value seen across them, and which columns were involved.
%
%   WHY THIS MATTERS
%
%   A mixer channel that hits the converter's limit stops reporting the
%   signal and starts reporting the limit.  The phase fit does not fail
%   when that happens - it fits the clipped waveform and returns a
%   confident, wrong answer, because a flat-topped sinusoid still has a
%   phase.  The same goes for the per-block lifetime estimate.  So this
%   has to be caught and said out loud rather than inferred later from a
%   calibration that will not reproduce.
%
%   The default rail is 9.99 V, just inside the +/-10 V range the board
%   is configured for.  A clipped sample reads at or fractionally under
%   the limit depending on the converter's calibration, so testing for
%   exactly 10 would miss it.
%
%   Only the four mixer channels are examined.  The DC channel carries an
%   offset that is legitimately large, and the extra inputs are whatever
%   the user attached.
%
%   See also CALIBRATION, FLIMIR_APPLY_INTENSITY_SIGN.

    if nargin < 2 || isempty(railVolts)
        railVolts = 9.99;
    end

    saturated = false;
    maxAbs = 0;
    channels = [];

    if isempty(data)
        return;
    end
    nMixer = min(4, size(data, 2));
    if nMixer < 1
        return;
    end

    block = abs(data(:, 1:nMixer));
    perChannel = max(block, [], 1, 'omitnan');
    perChannel(~isfinite(perChannel)) = 0;

    maxAbs = max(perChannel);
    channels = find(perChannel >= railVolts);
    saturated = ~isempty(channels);
end
