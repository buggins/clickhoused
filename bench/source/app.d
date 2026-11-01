/++
clickhoused benchmarks.

Usage: `dub run :bench -b release -- [--filter text] [--rows N] [--runs N] [--min-time seconds] [--csv file]`

On a noisy machine compare the `min ms` column: the median moves with
background load.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module app;

import benchmarks.offline : basicCases;
import benchmarks.runner : csvHeader, csvRow, markdownHeader, markdownRow, Result, runAll;

int main(string[] args)
{
    import std.getopt : defaultGetoptPrinter, getopt;
    import std.stdio : File, stdout, writeln;

    string filter;
    size_t rows;
    size_t runs = 5;
    double minTime = 1;
    string csv;
    // dfmt off
    auto help = getopt(args,
        "filter", "run the cases whose name contains this text", &filter,
        "rows", "rows per case (default: each case's own)", &rows,
        "runs", "minimum measured runs per case (default 5)", &runs,
        "min-time", "minimum measured seconds per case (default 1)", &minTime,
        "csv", "also write the results to this CSV file", &csv);
    // dfmt on
    if (help.helpWanted)
    {
        defaultGetoptPrinter("clickhoused benchmarks", help.options);
        return 0;
    }
    if (runs == 0)
        runs = 1;

    debug writeln("Note: a debug build; use `dub run :bench -b release` for meaningful numbers.");
    writeln(markdownHeader());
    void report(Result r)
    {
        writeln(markdownRow(r));
        stdout.flush();
    }

    import core.time : dur;

    const results = runAll(basicCases(), filter, rows, runs, dur!"msecs"(cast(long)(minTime * 1000)), &report);
    if (csv.length)
    {
        auto f = File(csv, "w");
        f.writeln(csvHeader);
        foreach (r; results)
            f.writeln(csvRow(r));
    }
    return 0;
}
