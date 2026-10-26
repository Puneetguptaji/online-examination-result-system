#!/usr/bin/env python3
"""
Online Examination Result System - web front end.

The website deliberately does almost nothing: it collects marks and displays
what the database decided. Percentages, grades, pass/fail, GPA, statistics and
ranks are all computed by MySQL functions, triggers and stored procedures.
"""

import csv
import io
import os
import re

from flask import (Flask, Response, flash, redirect, render_template, request,
                   url_for)
import pymysql
from pymysql.cursors import DictCursor

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "result-system-demo-key")

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

DB = dict(
    host=os.environ.get("DB_HOST", "127.0.0.1"),
    user=os.environ.get("DB_USER", "resultapp"),
    password=os.environ.get("DB_PASSWORD", "result@123"),
    database=os.environ.get("DB_NAME", "result_system"),
    cursorclass=DictCursor,
    autocommit=True,
)


def conn():
    return pymysql.connect(**DB)


def query(sql, args=None):
    c = conn()
    try:
        with c.cursor() as cur:
            cur.execute(sql, args or ())
            return cur.fetchall()
    finally:
        c.close()


def scalar(sql, args=None):
    rows = query(sql, args)
    if not rows:
        return None
    return list(rows[0].values())[0]


def db_error(exc):
    """Pull the readable message out of a MySQL error."""
    if len(exc.args) > 1:
        return str(exc.args[1])
    return str(exc)


def call_proc(proc, args=(), outs=()):
    """
    Call a stored procedure, drain its result sets, and fetch any OUT params.
    Returns (rows, out_dict).
    """
    c = conn()
    try:
        with c.cursor() as cur:
            placeholders = ",".join(["%s"] * len(args))
            tail = "".join(f",@{o}" for o in outs)
            cur.execute(f"CALL {proc}({placeholders}{tail})", args)
            try:
                rows = cur.fetchall()
            except pymysql.err.ProgrammingError:
                rows = []
            while cur.nextset():
                pass
            out = {}
            if outs:
                picks = ",".join(f"@{o} AS {o}" for o in outs)
                cur.execute(f"SELECT {picks}")
                out = cur.fetchone() or {}
            return rows, out
    finally:
        c.close()


def csv_response(filename, headers, rows):
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(headers)
    for r in rows:
        w.writerow(r)
    return Response(
        buf.getvalue(),
        mimetype="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


# --------------------------------------------------------------------- routes
@app.route("/")
def dashboard():
    q = (request.args.get("q") or "").strip()
    if q:
        like = f"%{q}%"
        students = query(
            "SELECT * FROM students WHERE roll_no LIKE %s OR full_name LIKE %s "
            "ORDER BY roll_no", (like, like))
    else:
        students = query("SELECT * FROM students ORDER BY roll_no")

    exams = query("SELECT * FROM exams ORDER BY exam_date DESC")
    summary = query("SELECT * FROM v_exam_summary ORDER BY exam_id")
    recent = query("SELECT * FROM v_result_summary ORDER BY result_id DESC LIMIT 10")
    totals = query("SELECT * FROM v_student_totals ORDER BY overall_rank")

    kpi = query("""
        SELECT (SELECT COUNT(*) FROM students)                  AS students,
               (SELECT COUNT(*) FROM exams)                     AS exams,
               (SELECT COUNT(*) FROM results)                   AS results,
               (SELECT ROUND(AVG(percentage),2) FROM results)   AS avg_pct,
               (SELECT ROUND(100*SUM(result_status='PASS')
                             /NULLIF(COUNT(*),0),1) FROM results) AS pass_rate
    """)[0]

    return render_template("dashboard.html", students=students, exams=exams,
                           summary=summary, recent=recent, totals=totals,
                           kpi=kpi, q=q)


@app.route("/exam/<int:exam_id>")
def exam_detail(exam_id):
    exam = query("SELECT * FROM exams WHERE exam_id=%s", (exam_id,))
    if not exam:
        flash("That exam does not exist.", "error")
        return redirect(url_for("dashboard"))

    merit = query("SELECT * FROM v_result_summary WHERE exam_id=%s "
                  "ORDER BY rank_no", (exam_id,))
    entered_ids = {r["student_id"] for r in merit}
    students = query("SELECT * FROM students WHERE is_active='Y' ORDER BY roll_no")
    dist = query("SELECT grade, COUNT(*) AS n FROM results WHERE exam_id=%s "
                 "GROUP BY grade ORDER BY grade", (exam_id,))
    stats, _ = call_proc("sp_class_statistics", [exam_id])
    return render_template("exam.html", exam=exam[0], merit=merit,
                           students=students, entered=entered_ids, dist=dist,
                           stats=stats[0] if stats else None)


# ------------------------------------------------------------------ entering
@app.route("/enter", methods=["POST"])
def enter_marks():
    """Enter one student's marks by calling sp_generate_result."""
    student_id = request.form.get("student_id", type=int)
    exam_id = request.form.get("exam_id", type=int)
    marks = request.form.get("marks", type=float)
    who = request.form.get("entered_by", "teacher") or "teacher"

    if not student_id or not exam_id or marks is None:
        flash("Please choose a student, an exam and enter the marks.", "error")
        return redirect(request.referrer or url_for("dashboard"))

    if marks < 0:
        flash("Marks cannot be negative.", "error")
        return redirect(request.referrer or url_for("dashboard"))

    try:
        _, out = call_proc("sp_generate_result",
                           [student_id, exam_id, marks, who],
                           outs=("rid", "msg"))
    except pymysql.MySQLError as e:
        flash(f"The database refused the entry: {db_error(e)}", "error")
        return redirect(url_for("exam_detail", exam_id=exam_id))

    if out.get("rid"):
        flash(f"{out['msg']} (result #{out['rid']})", "success")
    else:
        flash(out.get("msg") or "Rejected by the database.", "error")
    return redirect(url_for("exam_detail", exam_id=exam_id))


@app.route("/batch", methods=["POST"])
def batch_enter():
    """Enter a whole class at once: 'roll:marks, roll:marks, ...'"""
    exam_id = request.form.get("exam_id", type=int)
    data = (request.form.get("batch", "") or "").strip()

    if not exam_id or not data:
        flash("Paste the marks in the form  roll_no:marks, roll_no:marks", "error")
        return redirect(url_for("dashboard"))

    # The page takes roll numbers; the procedure wants student ids.
    pairs, unknown = [], []
    for chunk in re.split(r"[,;\n]+", data):
        if ":" not in chunk:
            continue
        roll, marks = chunk.split(":", 1)
        roll, marks = roll.strip(), marks.strip()
        if not roll or not marks:
            continue
        rows = query("SELECT student_id FROM students WHERE roll_no=%s", (roll,))
        if rows:
            pairs.append(f"{rows[0]['student_id']}:{marks}")
        else:
            unknown.append(roll)

    if not pairs:
        flash("No valid roll numbers found in that input.", "error")
        return redirect(url_for("dashboard"))

    try:
        _, out = call_proc("sp_generate_exam_results",
                           [exam_id, ",".join(pairs), "teacher"],
                           outs=("ins", "skipv"))
    except pymysql.MySQLError as e:
        flash(f"The database refused the batch: {db_error(e)}", "error")
        return redirect(url_for("exam_detail", exam_id=exam_id))

    made = out.get("ins") or 0
    skipped = out.get("skipv") or 0
    msg = (f"{made} result(s) created, {skipped} skipped "
           f"(duplicates or marks over the paper maximum are skipped by the database).")
    if unknown:
        msg += f" Unknown roll number(s): {', '.join(unknown)}."
    flash(msg, "success" if made else "error")
    return redirect(url_for("exam_detail", exam_id=exam_id))


# ------------------------------------------------------------------- editing
@app.route("/result/<int:result_id>/edit", methods=["GET", "POST"])
def edit_result(result_id):
    row = query("SELECT * FROM v_result_summary WHERE result_id=%s", (result_id,))
    if not row:
        flash("No such result.", "error")
        return redirect(url_for("dashboard"))
    row = row[0]

    if request.method == "POST":
        new_marks = request.form.get("marks", type=float)
        if new_marks is None:
            flash("Enter the new marks.", "error")
            return redirect(url_for("edit_result", result_id=result_id))
        try:
            call_proc("sp_update_marks", [result_id, new_marks, "teacher"])
        except pymysql.MySQLError as e:
            flash(f"The database refused the change: {db_error(e)}", "error")
            return redirect(url_for("edit_result", result_id=result_id))
        flash("Marks corrected. The trigger recalculated the percentage and the "
              "grade, and wrote the change to the audit trail.", "success")
        return redirect(url_for("exam_detail", exam_id=row["exam_id"]))

    trail = query("SELECT * FROM result_audit WHERE result_id=%s "
                  "ORDER BY audit_id DESC", (result_id,))
    return render_template("edit_result.html", row=row, trail=trail)


@app.route("/result/<int:result_id>/delete", methods=["POST"])
def delete_result(result_id):
    row = query("SELECT exam_id FROM results WHERE result_id=%s", (result_id,))
    if not row:
        flash("No such result.", "error")
        return redirect(url_for("dashboard"))
    exam_id = row[0]["exam_id"]
    try:
        call_proc("sp_delete_result", [result_id, "teacher"])
        flash(f"Result #{result_id} deleted. The delete is recorded in the audit trail.", "success")
    except pymysql.MySQLError as e:
        flash(f"The database refused the delete: {db_error(e)}", "error")
    return redirect(url_for("exam_detail", exam_id=exam_id))


# ------------------------------------------------------------------- reports
@app.route("/student/<int:student_id>")
def student_report(student_id):
    who = query("SELECT * FROM students WHERE student_id=%s", (student_id,))
    if not who:
        flash("Student not found.", "error")
        return redirect(url_for("dashboard"))
    rows, _ = call_proc("sp_student_report", [student_id])
    total = query("SELECT * FROM v_student_totals WHERE student_id=%s", (student_id,))
    return render_template("student.html", student=who[0], rows=rows,
                           total=total[0] if total else None)


@app.route("/transcript/<int:student_id>")
def transcript(student_id):
    """A printable mark sheet."""
    who = query("SELECT * FROM students WHERE student_id=%s", (student_id,))
    if not who:
        flash("Student not found.", "error")
        return redirect(url_for("dashboard"))
    rows, _ = call_proc("sp_student_report", [student_id])
    total = query("SELECT * FROM v_student_totals WHERE student_id=%s", (student_id,))
    return render_template("transcript.html", student=who[0], rows=rows,
                           total=total[0] if total else None)


@app.route("/ranks")
def ranks():
    rows = query("SELECT * FROM v_result_summary ORDER BY exam_id, rank_no")
    totals = query("SELECT * FROM v_student_totals ORDER BY overall_rank")
    return render_template("ranks.html", rows=rows, totals=totals)


@app.route("/analytics")
def analytics():
    exams = query("SELECT * FROM exams ORDER BY exam_date DESC")
    stats = []
    for e in exams:
        rows, _ = call_proc("sp_class_statistics", [e["exam_id"]])
        if rows:
            stats.append(rows[0])

    subjects = query("SELECT * FROM v_subject_summary ORDER BY average_pct DESC")
    grades = query("""
        SELECT grade, COUNT(*) AS n, ROUND(fn_grade_points(grade),1) AS points
          FROM results GROUP BY grade
         ORDER BY points DESC
    """)
    totals = query("SELECT * FROM v_student_totals ORDER BY overall_rank")
    dist = query("SELECT * FROM v_grade_distribution ORDER BY exam_id, grade")
    grand = query("""
        SELECT COUNT(*) AS results, ROUND(AVG(percentage),2) AS avg_pct,
               ROUND(STDDEV(percentage),2) AS std_dev,
               MAX(percentage) AS best, MIN(percentage) AS worst,
               ROUND(100*SUM(result_status='PASS')/NULLIF(COUNT(*),0),2) AS pass_rate
          FROM results
    """)[0]
    return render_template("analytics.html", stats=stats, subjects=subjects,
                           grades=grades, totals=totals, dist=dist, grand=grand)


@app.route("/audit")
def audit_log():
    trail = query("SELECT * FROM result_audit ORDER BY audit_id DESC LIMIT 200")
    counts = query("SELECT action, COUNT(*) AS n FROM result_audit GROUP BY action")
    return render_template("audit.html", trail=trail, counts=counts)


@app.route("/whatif")
def whatif():
    """Try a mark against a paper and see the database's own verdict."""
    exam_id = request.args.get("exam_id", type=int)
    marks = request.args.get("marks", type=float)
    exams = query("SELECT * FROM exams ORDER BY exam_date DESC")
    result = None

    if exam_id and marks is not None:
        exam = query("SELECT * FROM exams WHERE exam_id=%s", (exam_id,))
        if exam:
            exam = exam[0]
            result = query("""
                SELECT fn_calc_percentage(%s,%s) AS pct,
                       fn_get_grade(fn_calc_percentage(%s,%s)) AS grade,
                       fn_grade_points(fn_get_grade(fn_calc_percentage(%s,%s))) AS points,
                       IF(%s >= %s*0.40,'PASS','FAIL') AS status,
                       %s AS marks_typed
            """, (marks, exam["max_marks"], marks, exam["max_marks"],
                  marks, exam["max_marks"], marks, exam["max_marks"],
                  marks))[0]
            result["exam"] = exam
            result["marks"] = marks

    return render_template("whatif.html", exams=exams, result=result,
                           exam_id=exam_id, marks=marks)


# ------------------------------------------------------------------- exports
@app.route("/exam/<int:exam_id>/export.csv")
def export_exam(exam_id):
    exam = query("SELECT * FROM exams WHERE exam_id=%s", (exam_id,))
    if not exam:
        flash("That exam does not exist.", "error")
        return redirect(url_for("dashboard"))
    rows = query("SELECT * FROM v_result_summary WHERE exam_id=%s "
                 "ORDER BY rank_no", (exam_id,))
    data = [(r["rank_no"], r["roll_no"], r["full_name"], r["marks_obtained"],
             r["max_marks"], r["percentage"], r["grade"], r["result_status"])
            for r in rows]
    name = re.sub(r"[^A-Za-z0-9]+", "_", exam[0]["exam_name"]).strip("_")
    return csv_response(f"{name}_merit_list.csv",
                        ["rank", "roll_no", "name", "marks", "max_marks",
                         "percentage", "grade", "status"], data)


@app.route("/export/results.csv")
def export_all():
    rows = query("SELECT * FROM v_result_summary ORDER BY exam_id, rank_no")
    data = [(r["exam_id"], r["exam_name"], r["rank_no"], r["roll_no"],
             r["full_name"], r["marks_obtained"], r["max_marks"],
             r["percentage"], r["grade"], r["result_status"])
            for r in rows]
    return csv_response("all_results.csv",
                        ["exam_id", "exam", "rank", "roll_no", "name", "marks",
                         "max_marks", "percentage", "grade", "status"], data)


@app.route("/export/students.csv")
def export_students():
    rows = query("SELECT * FROM v_student_totals ORDER BY overall_rank")
    data = [(r["overall_rank"], r["roll_no"], r["full_name"], r["exams_taken"],
             r["total_marks"], r["total_max"], r["overall_pct"], r["gpa"])
            for r in rows]
    return csv_response("student_totals.csv",
                        ["overall_rank", "roll_no", "name", "exams", "total_marks",
                         "total_max", "overall_pct", "gpa"], data)


# ------------------------------------------------------- proof-of-rules page
@app.route("/proof")
def proof():
    """
    Runs each database rule live and records what happened, so a visitor can
    see the database refusing bad data rather than taking it on trust.
    """
    results = []

    def attempt(label, sql, args=None):
        c = conn()
        try:
            with c.cursor() as cur:
                cur.execute(sql, args or ())
            results.append((label, "ALLOWED", "the database permitted this row"))
        except pymysql.MySQLError as e:
            results.append((label, "REFUSED", db_error(e)))
        finally:
            c.close()

    # Pick a student/exam pair that is guaranteed not to exist yet, so the
    # "allowed" case never actually leaves junk behind.
    attempt("Insert 150 marks into a 75-mark paper",
            "INSERT INTO results (student_id,exam_id,marks_obtained) VALUES (8,4,150)")
    attempt("Insert a second result for the same student and exam",
            "INSERT INTO results (student_id,exam_id,marks_obtained) VALUES (1,1,70)")
    attempt("Insert a result for a student who does not exist",
            "INSERT INTO results (student_id,exam_id,marks_obtained) VALUES (9999,1,50)")
    attempt("Insert a negative mark",
            "INSERT INTO results (student_id,exam_id,marks_obtained) VALUES (8,4,-5)")
    attempt("Update a result to exceed the paper maximum",
            "UPDATE results SET marks_obtained = 500 WHERE result_id = 1")
    attempt("Insert a student with a duplicate roll number",
            "INSERT INTO students (roll_no,full_name,email) "
            "VALUES ('26MCI10246','Copy Cat','copy@examai.edu')")

    trig = query("""
        SELECT marks_obtained, percentage, grade, result_status
          FROM results WHERE exam_id = 1 ORDER BY percentage DESC LIMIT 3
    """)

    fn = query("""
        SELECT fn_calc_percentage(87,100)        AS pct_87,
               fn_get_grade(87.00)               AS grade_87,
               fn_get_grade(33.00)               AS grade_33,
               fn_grade_points(fn_get_grade(87.00)) AS points_87
    """)[0]

    audit = query("SELECT * FROM result_audit ORDER BY audit_id DESC LIMIT 10")
    return render_template("proof.html", results=results, trig=trig, fn=fn,
                           audit=audit)


# ----------------------------------------------------------------- utilities
@app.route("/admin/reset", methods=["POST"])
def reset_demo():
    """Put the demo data back the way it was, for a viva."""
    try:
        c = conn()
        try:
            with c.cursor() as cur:
                cur.execute("SET FOREIGN_KEY_CHECKS=0")
                for t in ("result_audit", "results", "exams", "students"):
                    cur.execute(f"DELETE FROM {t}")
                    cur.execute(f"ALTER TABLE {t} AUTO_INCREMENT = 1")
                cur.execute("SET FOREIGN_KEY_CHECKS=1")
        finally:
            c.close()

        with open(os.path.join(BASE_DIR, "02_seed_data.sql"), encoding="utf-8") as f:
            sql = f.read()
        sql = re.sub(r"--[^\n]*", "", sql)
        sql = sql.replace("USE result_system;", "")
        c = conn()
        try:
            with c.cursor() as cur:
                for stmt in [s.strip() for s in sql.split(";")]:
                    if stmt:
                        cur.execute(stmt)
        finally:
            c.close()
        flash("Demo data restored: 8 students, 4 exams, 17 results.", "success")
    except Exception as e:                       # noqa: BLE001 - show anything
        flash(f"Reset failed: {e}", "error")
    return redirect(url_for("dashboard"))


# ------------------------------------------------------------ error handlers
@app.errorhandler(404)
def not_found(e):
    return render_template("error.html", code=404,
                           title="Page not found",
                           detail="That address does not exist in this system."), 404


@app.errorhandler(500)
def server_error(e):
    return render_template("error.html", code=500,
                           title="Something went wrong",
                           detail="The page hit an error. Try again, or go back "
                                  "to the dashboard."), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
