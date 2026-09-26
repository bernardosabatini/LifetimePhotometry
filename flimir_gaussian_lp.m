function filtered = flimir_gaussian_lp(data, sd)
% FLIMIR_GAUSSIAN_LP  Gaussian low-pass that does not shift the DC level.
%
%   filtered = flimir_gaussian_lp(data, sd)
%
%   Translated from gaussianFilter.m / bestLPFilter.m.  sd is the Gaussian
%   standard deviation in SAMPLES; the old code called it as
%   bestLPFilter(data, fpass, fs) -> gaussianFilter(data, fs/fpass), so
%   sd = sampleRate / cutoffHz.  MATLAB's lowpass() sometimes introduces a
%   DC offset, which is unacceptable here; this does not.
%
%   The edges are padded with the mean of the first/last sd samples before
%   filtering and trimmed afterwards, matching the original.
%
%   Two differences from the original, both to keep the per-block real-time
%   path bounded:
%     - When the kernel is at least as wide as the data, the result is the
%       data's mean, which is what the filter converges to anyway.  At a
%       0.1 s block and a 20 Hz cutoff this is always the case, whatever
%       the sample rate.
%     - Long kernels convolve via FFT, so cost stays O(N log N) instead of
%       O(N*kernelLength).
%
%   Returns a row vector the same length as data.

    FFT_THRESHOLD = 2e7;   % N * kernelLength above which FFT is cheaper

    data = data(:)';
    n = numel(data);
    if n == 0
        filtered = data;
        return;
    end

    sd = max(1, round(sd));
    kernelLength = 6 * sd + 1;

    % Kernel wider than the data: the filter is just the mean
    if kernelLength >= n
        filtered = repmat(mean(data), 1, n);
        return;
    end

    % Gaussian written out rather than called from normpdf, so this file
    % needs no toolbox.  The 1/sqrt(2*pi) scaling cancels in the
    % normalisation on the next line, but it is kept so the expression
    % reads as the density it is.
    z = (-3 * sd:3 * sd) / sd;
    kernel = exp(-0.5 * z.^2) / sqrt(2 * pi);
    kernel = kernel ./ sum(kernel);

    nPad = min(sd, n);
    padded = [ones(1, 3 * sd) * mean(data(1:nPad)), ...
              data, ...
              ones(1, 3 * sd) * mean(data(end - nPad + 1:end))];

    if n * kernelLength > FFT_THRESHOLD
        m = numel(padded) + kernelLength - 1;
        nfft = 2^nextpow2(m);
        y = ifft(fft(padded, nfft) .* fft(kernel, nfft), 'symmetric');
        filtered = y(6 * sd + (1:n));
    else
        y = filter(kernel, 1, padded);
        filtered = y(6 * sd + (1:n));
    end
end
