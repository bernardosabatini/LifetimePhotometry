function volts = flimir_power_to_volts(power, minVolts, maxVolts)
%FLIMIR_POWER_TO_VOLTS  Laser power fraction to control voltage.
%
%   volts = flimir_power_to_volts(power, minVolts, maxVolts)
%
%   power is 0 to 1, where 0 is dark and 1 is full power.  minVolts is
%   the control voltage that produces no light and maxVolts the one that
%   produces full light.
%
%   WHY POWER IS A FRACTION
%
%   Every rig expresses "off" differently.  A laser driven directly is
%   off at 0 V; a voltage-controlled attenuator is off at full scale; a
%   particular head might only be usable between 4.2 V and 1.1 V.  A
%   control calibrated in volts therefore means something different on
%   each rig, and code that assumes "0 is off" or "more volts is more
%   light" is wrong on half of them.
%
%   Expressing the setting as a fraction moves that knowledge into two
%   numbers the user measures once.  0 is always dark and 1 is always
%   full, whatever the hardware does, and every other part of the
%   application can reason about power without knowing the wiring.
%
%   REVERSED RANGES
%
%   maxVolts may be below minVolts - that is what an attenuator is - and
%   nothing here treats it as a special case.  The interpolation handles
%   it, so inversion is not a separate mode with its own bugs; it is
%   just which way round the two numbers were entered.
%
%   power outside 0..1 is clamped, since driving past the calibrated
%   ends is asking the hardware for something the user did not describe.
%
%   See also FLIMIR_VOLTS_TO_POWER.

    if isempty(power)
        volts = [];
        return;
    end
    power = max(0, min(1, power));
    volts = minVolts + power .* (maxVolts - minVolts);
end
