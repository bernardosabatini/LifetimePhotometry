function power = flimir_volts_to_power(volts, minVolts, maxVolts)
%FLIMIR_VOLTS_TO_POWER  Control voltage back to a laser power fraction.
%
%   power = flimir_volts_to_power(volts, minVolts, maxVolts)
%
%   The inverse of flimir_power_to_volts: 0 for the voltage that gives no
%   light, 1 for the voltage that gives full light, clamped outside.
%
%   Used when a stored setting or a piece of hardware reports a voltage
%   and the application needs it as a fraction - loading a settings file
%   written before power was expressed this way, for instance.
%
%   A zero-width range (the two voltages equal) has no meaningful
%   inverse; it returns 0, which is the safe end.
%
%   See also FLIMIR_POWER_TO_VOLTS.

    span = maxVolts - minVolts;
    if abs(span) < eps
        power = zeros(size(volts));
        return;
    end
    power = (volts - minVolts) ./ span;
    power = max(0, min(1, power));
end
