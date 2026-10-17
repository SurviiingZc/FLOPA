"""Audit the actually selected short UVM test logs; fail closed on missing evidence."""

import json
import hashlib
import re
import sys
from pathlib import Path


def main():
    output = Path(sys.argv[1]).resolve()
    names = output.joinpath("selected_tests.txt").read_text().split()
    results = []
    for name in names:
        path = output / f"{name}.log"
        text = path.read_text(errors="replace") if path.exists() else ""
        errors = re.findall(r"^UVM_ERROR\s*:\s*(\d+)", text, flags=re.M)
        fatals = re.findall(r"^UVM_FATAL\s*:\s*(\d+)", text, flags=re.M)
        summaries = re.findall(r"completed_jobs=(\d+) checked_bytes=(\d+)", text)
        job_rows = re.findall(r"\[RUNTIME_JOB\]\s*(job=.*)", text)
        jobs = [dict(re.findall(r"(\w+)=(\d+)", row)) for row in job_rows]
        non_uvm_error = bool(re.search(r"^Error:|^Fatal:|Assertion.*failed", text, re.M))
        passed = bool(errors and fatals and summaries and jobs)
        passed &= errors[-1:] == ["0"] and fatals[-1:] == ["0"] and not non_uvm_error
        passed &= bool(summaries and int(summaries[-1][0]) == len(jobs))
        expected_jobs = {
            "fa_runtime_d_smoke_test": 5,
            "fa_runtime_d_range_test": 128,
            "fa_runtime_d_boundary_test": 12,
            "fa_runtime_d_multihead_test": 3,
            "fa_runtime_d_control_test": 3,
            "fa_runtime_d_arith_test": 6,
        }
        passed &= len(jobs) == expected_jobs.get(name, len(jobs))
        if name == "fa_runtime_d_range_test":
            passed &= {int(job["d"]) for job in jobs} == set(range(1, 129))
        row = {
            "test": name,
            "pass": passed,
            "uvm_errors": int(errors[-1]) if errors else None,
            "uvm_fatals": int(fatals[-1]) if fatals else None,
            "completed_jobs": int(summaries[-1][0]) if summaries else 0,
            "checked_bytes": int(summaries[-1][1]) if summaries else 0,
            "job_details": [{key: int(value) for key, value in job.items()} for job in jobs],
            "log": str(path),
            "log_sha256": hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None,
        }
        results.append(row)
    report = {
        "pass": bool(results) and all(row["pass"] for row in results),
        "clock_period_ns": 10,
        "boundary": "functional serial-producer RTL; cycles include programming and load stalls",
        "tests": results,
    }
    output.joinpath("summary.json").write_text(json.dumps(report, indent=4) + "\n")
    lines = [
        f"{'PASS' if row['pass'] else 'FAIL'} {row['test']} "
        f"errors={row['uvm_errors']} fatals={row['uvm_fatals']} "
        f"jobs={row['completed_jobs']} bytes={row['checked_bytes']} log={row['log']}"
        for row in results
    ]
    output.joinpath("summary.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
