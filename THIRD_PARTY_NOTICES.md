# Third-party notices

clickhoused is licensed under the [Boost Software License 1.0](LICENSE). It contains one piece of third-party code, which keeps its original license:

## CityHash v1.0.2

`source/clickhoused/compress/cityhash.d` is a D port of CityHash version 1.0.2 (by Geoff Pike and Jyrki Alakuijala), as included in ClickHouse (`contrib/cityhash102`). ClickHouse uses this exact version for the checksums of compressed network blocks.

```
Copyright (c) 2011 Google, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

The LZ4 codec (`source/clickhoused/compress/lz4.d`) is an original implementation written from the LZ4 block format specification and contains no code from the LZ4 library.

The optional ZSTD support (`zstd` dub configuration) links to the system zstd library, which is not distributed with clickhoused (zstd is dual-licensed BSD-3-Clause / GPLv2).
