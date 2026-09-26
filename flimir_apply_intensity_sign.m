function data = flimir_apply_intensity_sign(data, invert)
%FLIMIR_APPLY_INTENSITY_SIGN  Flip the DC/intensity channel if the detector
%is negative-going.
%
%   data = flimir_apply_intensity_sign(data, invert)
%
%   data is nSamples-by-nChannels with the DC/intensity channel in column
%   5.  When invert is true that column is multiplied by -1; everything
%   else is untouched.
%
%   WHY THIS EXISTS, AND WHY IT IS ONE FUNCTION
%
%   A PMT sources anode current, so a transimpedance front end usually
%   reads MORE NEGATIVE with more light.  The analysis assumes the
%   opposite: the modulation depth is
%
%       MoverB = mean(dVIF) * sqrt(1 + (tau*omega)^2) / (2 * mean(VDC))
%
%   and calculate_tau_s_g normalises by that same mean VDC.  A negative
%   VDC therefore flips the sign of the modulation depth and quietly
%   biases every lifetime rather than failing outright.
%
%   The fix is to put the signal the right way up once, before anything
%   measures it.  That has to happen at the SAME point for the dark
%   baseline as for the data it will be subtracted from, or the offset
%   goes on with the wrong sign and the error is twice the offset.  So:
%
%       invert first, subtract the dark offset second, always.
%
%   With that ordering the dark offset is measured in whatever convention
%   the data is already in and no downstream code needs to know:
%
%       VDC = (-ai4) - mean(-ai4_dark) = -(ai4 - mean(ai4_dark))
%
%   which is positive when light drives ai4 negative, as intended.
%
%   Keeping it in one function rather than inlining `-data(:,5)` in three
%   places is the point: acquisition, the dark measurement and the
%   calibration sweep must agree, and three copies of a sign convention
%   is how they stop agreeing.
%
%   Note that taking abs(VDC) instead would also produce a positive
%   number, but it would hide a genuinely mis-wired detector and make a
%   sign error impossible to detect downstream.  The flag is explicit
%   and travels with the data instead.
%
%   See also DARK_CALIBRATION, CALIBRATION, CALCULATE_TAU_S_G.

    if nargin < 2 || ~invert
        return;
    end
    if size(data, 2) >= 5
        data(:, 5) = -data(:, 5);
    end
end
