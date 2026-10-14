CompactSlider by Alexey Bukhtin — https://github.com/buh/CompactSlider (MIT, see LICENSE)
Vendored into Fire so that it builds with the macOS 27 SDK.
Change: ProminentCompactSliderStyle.swift wraps the LinearGradient in Rectangle().fill(...)
because `.opacity` on a gradient became ambiguous in the macOS 27 SDK.
