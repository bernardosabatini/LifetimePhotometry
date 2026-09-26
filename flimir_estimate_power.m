function [microwatts, status] = flimir_estimate_power(lut, volts)
%FLIMIR_ESTIMATE_POWER  Output power for a control voltage, from a LUT.
%
%   [microwatts, status] = flimir_estimate_power(lut, volts)
%
%   Interpolates the measured table at the given control voltage.
%   status is 'ok' inside the measured range, 'below range' or 'above
%   range' outside it, and 'no LUT' when none is loaded.  microwatts is
%   NaN in every case except 'ok'.
%
%   WHY IT INTERPOLATES RATHER THAN FITTING A CURVE
%
%   The table is measured on a 0.1 V grid, which is dense compared with
%   how fast the output changes, so a shape-preserving interpolant
%   passes through every measured point and invents nothing between
%   them.  Fitting a polynomial instead would move the curve away from
%   points that were actually measured in order to satisfy points that
%   were not, and a high-order fit through a monotone attenuator curve
%   is prone to ringing between samples.  pchip is used rather than
%   spline for the same reason: it will not overshoot between points,
%   so an interpolated power can never exceed the measured neighbours.
%
%   WHY IT REFUSES TO EXTRAPOLATE
%
%   The LUT is partial by construction - it covers the range where the
%   system produces usable power, and stops. Outside that range the
%   behaviour is not merely unmeasured, it is the region the measurement
%   deliberately excluded, often where the output collapses or the
%   relationship changes shape entirely. An extrapolated number there
%   would look as authoritative as a measured one and be wrong by an
%   unknown amount, which is worse than no number at all. So the caller
%   is told the setting is outside the table and given NaN.
%
%   See also FLIMIR_LOAD_POWER_LUT.

    microwatts = NaN;
    status = 'no LUT';

    if isempty(lut) || ~isstruct(lut) || ~isfield(lut, 'volts')
        return;
    end
    if isempty(volts) || ~isfinite(volts)
        status = 'no setting';
        return;
    end

    lo = lut.voltRange(1);
    hi = lut.voltRange(2);
    tol = 1e-9;
    if volts < lo - tol
        status = 'below range';
        return;
    end
    if volts > hi + tol
        status = 'above range';
        return;
    end

    microwatts = interp1(lut.volts, lut.microwatts, ...
        min(max(volts, lo), hi), 'pchip');
    status = 'ok';
end
