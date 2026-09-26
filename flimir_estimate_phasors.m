function [theta, R, S, G] = flimir_estimate_phasors(phi, VIF)
% FLIMIR_ESTIMATE_PHASORS  Least-squares phasor from four mixer channels.
%
%   [theta, R, S, G] = flimir_estimate_phasors(phi, VIF)
%
%   Translated from estimatePhasors.m.  Solves, for every column of VIF,
%   the two-parameter least squares problem
%
%       VIF_i = S*cos(phi_i) + G*sin(phi_i)
%
%   and returns the polar form.  Used both by the calibration fit and by
%   the per-block lifetime estimate, so they cannot drift apart.
%
%   Inputs:
%       phi - 4 x 1 channel phases (rad)
%       VIF - 4 x N normalised mixer channel values
%
%   Outputs:
%       theta - 1 x N phasor angle (rad)
%       R     - 1 x N phasor magnitude
%       S     - 1 x N phasor S coordinate
%       G     - 1 x N phasor G coordinate

    A = [cos(phi(:)), sin(phi(:))];
    phasors = (A' * A) \ (A' * VIF);
    S = phasors(1, :);
    G = phasors(2, :);
    [theta, R] = cart2pol(G, S);
end
