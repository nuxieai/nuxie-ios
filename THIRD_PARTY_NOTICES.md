# Third-Party Notices

The Nuxie iOS SDK includes or derives from the following MIT-licensed projects.
The complete MIT terms reproduced below apply to each listed copyright holder.

## ShimmerView

Copyright (c) 2020 Mercari, Inc.

Source: https://github.com/mercari/ShimmerView

The shimmering loading treatment in
`Sources/Nuxie/Experiences/ExperienceViewController+iOS.swift` ports
ShimmerView's effect geometry: squaring the gradient layer so the effect angle
is independent of aspect ratio, deriving travel from the effect radius and span
so the band clears the surface at any angle, animating `startPoint`/`endPoint`
rather than the clamped `locations`, smoothstep-interpolated gradient stops, and
the nested animation group that produces the interval between traversals.

---

## MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
