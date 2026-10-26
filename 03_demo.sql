-- ============================================================================
--  PROJECT : Online Examination Result System
--  FILE    : 03_demo.sql
--  Direct console demonstration, without the web page in the way.
--  Run with:   mysql -u root --force < 03_demo.sql
--  The --force flag lets the script continue after the deliberate failures.
-- ============================================================================
USE result_system;

SELECT 'STEP 1  Object counts in the schema' AS 'step';
SELECT (SELECT COUNT(*) FROM information_schema.tables
         WHERE table_schema='result_system' AND table_type='BASE TABLE') AS tables,
       (SELECT COUNT(*) FROM information_schema.views
         WHERE table_schema='result_system')                            AS views,
       (SELECT COUNT(*) FROM information_schema.routines
         WHERE routine_schema='result_system' AND routine_type='FUNCTION')    AS functions,
       (SELECT COUNT(*) FROM information_schema.routines
         WHERE routine_schema='result_system' AND routine_type='PROCEDURE')   AS procedures,
       (SELECT COUNT(*) FROM information_schema.triggers
         WHERE trigger_schema='result_system')                          AS triggers;

SELECT 'STEP 2  The functions, called directly' AS 'step';
SELECT fn_calc_percentage(68, 100) AS pct_68_of_100,
       fn_calc_percentage(52, 75)  AS pct_52_of_75,
       fn_get_grade(92.00)         AS grade_92,
       fn_get_grade(87.00)         AS grade_87,
       fn_get_grade(33.00)         AS grade_33,
       fn_grade_points('A+')       AS points_Aplus,
       fn_grade_points('F')        AS points_F;

SELECT 'STEP 3  A temporary exam is created for the demonstration' AS 'step';
DELETE FROM exams WHERE exam_name = 'DEMO Quiz';
INSERT INTO exams (exam_name, subject, max_marks, exam_date, exam_type)
VALUES ('DEMO Quiz', 'Operating Systems', 50, '2026-10-02', 'INTERNAL');
SET @demo_exam = LAST_INSERT_ID();
SELECT @demo_exam AS demo_exam_id, 50 AS max_marks;

SELECT 'STEP 4  Only marks supplied; the trigger fills the rest' AS 'step';
INSERT INTO results (student_id, exam_id, marks_obtained, entered_by)
VALUES (1, @demo_exam, 47, 'demo'),
       (2, @demo_exam, 41, 'demo'),
       (5, @demo_exam, 29, 'demo');
SELECT s.roll_no, r.marks_obtained, r.percentage, r.grade, r.result_status
  FROM results r JOIN students s ON s.student_id = r.student_id
 WHERE r.exam_id = @demo_exam
 ORDER BY r.percentage DESC;

SELECT 'STEP 5  Four bad writes, refused by the database' AS 'step';

SELECT ' > 80 marks into a 50-mark paper' AS 'step';
INSERT INTO results (student_id, exam_id, marks_obtained) VALUES (3, @demo_exam, 80);

SELECT ' > a second result for student 1 in the same exam' AS 'step';
INSERT INTO results (student_id, exam_id, marks_obtained) VALUES (1, @demo_exam, 40);

SELECT ' > a result for student 9999, who does not exist' AS 'step';
INSERT INTO results (student_id, exam_id, marks_obtained) VALUES (9999, @demo_exam, 40);

SELECT ' > a negative mark' AS 'step';
INSERT INTO results (student_id, exam_id, marks_obtained) VALUES (3, @demo_exam, -5);

SELECT 'STEP 6  None of the four bad rows were stored' AS 'step';
SELECT COUNT(*) AS rows_for_demo_exam FROM results WHERE exam_id = @demo_exam;
SELECT s.roll_no, r.marks_obtained, r.percentage, r.grade, r.result_status
  FROM results r JOIN students s ON s.student_id = r.student_id
 WHERE r.exam_id = @demo_exam
 ORDER BY r.percentage DESC;

SELECT 'STEP 7  Rank calculation for the demonstration exam' AS 'step';
CALL sp_merit_list(@demo_exam);

SELECT 'STEP 8  Class statistics from sp_class_statistics' AS 'step';
CALL sp_class_statistics(@demo_exam);

SELECT 'STEP 9  Correcting a mark; the trigger regrades it' AS 'step';
SET @demo_result = (SELECT result_id FROM results
                     WHERE exam_id = @demo_exam AND student_id = 2);
SELECT @demo_result AS result_id, 41 AS old_marks, 19 AS new_marks;
CALL sp_update_marks(@demo_result, 19, 'demo');
SELECT marks_obtained, percentage, grade, result_status
  FROM results WHERE result_id = @demo_result;

SELECT 'STEP 10  Audit trail written by the triggers' AS 'step';
SELECT result_id, action, old_marks, new_marks, changed_by
  FROM result_audit
 WHERE result_id IN (SELECT result_id FROM results WHERE exam_id = @demo_exam)
 ORDER BY audit_id;

SELECT 'STEP 11  Clean up the demonstration exam' AS 'step';
DELETE FROM results WHERE exam_id = @demo_exam;
DELETE FROM exams WHERE exam_id = @demo_exam;
SELECT COUNT(*) AS demo_exam_left FROM exams WHERE exam_name = 'DEMO Quiz';

SELECT 'STEP 12  Overall standing, from v_student_totals' AS 'step';
SELECT overall_rank, roll_no, full_name, exams_taken,
       CONCAT(total_marks, ' / ', total_max) AS total,
       overall_pct, gpa
  FROM v_student_totals
 ORDER BY overall_rank;
