-- ============================================================================
--  PROJECT : Online Examination Result System
--  FILE    : 01_schema.sql
--  DATABASE: MySQL 8 / MariaDB 10.5+  (tested on MariaDB 11.8)
--
--  Stores exam marks, calculates percentages, assigns grades and ranks
--  students. All three of those calculations are done by the DATABASE, not by
--  the website, so they cannot be skipped or faked by any client.
-- ============================================================================

DROP DATABASE IF EXISTS result_system;
CREATE DATABASE result_system CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE result_system;

-- ---------------------------------------------------------------------------
-- 1. STUDENTS
-- ---------------------------------------------------------------------------
CREATE TABLE students (
    student_id   INT AUTO_INCREMENT PRIMARY KEY,
    roll_no      VARCHAR(15)  NOT NULL UNIQUE,
    full_name    VARCHAR(100) NOT NULL,
    email        VARCHAR(120) NOT NULL UNIQUE,
    program      VARCHAR(50)  DEFAULT 'MCA',
    semester     INT          DEFAULT 1,
    is_active    CHAR(1)      DEFAULT 'Y',
    created_at   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_student_sem CHECK (semester BETWEEN 1 AND 8),
    CONSTRAINT chk_student_act CHECK (is_active IN ('Y','N'))
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- 2. EXAMS
-- ---------------------------------------------------------------------------
CREATE TABLE exams (
    exam_id     INT AUTO_INCREMENT PRIMARY KEY,
    exam_name   VARCHAR(100) NOT NULL,
    subject     VARCHAR(80)  NOT NULL,
    max_marks   INT          NOT NULL,
    exam_date   DATE         NOT NULL,
    exam_type   VARCHAR(20)  DEFAULT 'THEORY',
    created_at  TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_exam_marks CHECK (max_marks BETWEEN 1 AND 500),
    CONSTRAINT chk_exam_type  CHECK (exam_type IN ('THEORY','PRACTICAL','INTERNAL'))
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------------
-- 3. RESULTS
--    percentage, grade and result_status are filled in by a trigger, so a row
--    is never stored without them, even if someone inserts raw SQL.
-- ---------------------------------------------------------------------------
CREATE TABLE results (
    result_id      INT AUTO_INCREMENT PRIMARY KEY,
    student_id     INT          NOT NULL,
    exam_id        INT          NOT NULL,
    marks_obtained DECIMAL(6,2) NOT NULL,
    percentage     DECIMAL(5,2) DEFAULT NULL,
    grade          VARCHAR(2)   DEFAULT NULL,
    result_status  VARCHAR(10)  DEFAULT NULL,
    entered_by     VARCHAR(50)  DEFAULT 'system',
    created_at     TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_result_student FOREIGN KEY (student_id)
        REFERENCES students(student_id) ON DELETE CASCADE,
    CONSTRAINT fk_result_exam FOREIGN KEY (exam_id)
        REFERENCES exams(exam_id) ON DELETE CASCADE,
    CONSTRAINT uq_result_once UNIQUE (student_id, exam_id),
    CONSTRAINT chk_marks_positive CHECK (marks_obtained >= 0)
) ENGINE=InnoDB;

CREATE INDEX idx_results_exam    ON results (exam_id);
CREATE INDEX idx_results_student ON results (student_id);
CREATE INDEX idx_results_pct     ON results (exam_id, percentage);

-- ---------------------------------------------------------------------------
-- 4. AUDIT LOG  (written by trigger only)
-- ---------------------------------------------------------------------------
CREATE TABLE result_audit (
    audit_id   INT AUTO_INCREMENT PRIMARY KEY,
    result_id  INT,
    action     VARCHAR(10),
    old_marks  DECIMAL(6,2),
    new_marks  DECIMAL(6,2),
    changed_by VARCHAR(50),
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ============================================================================
--  FUNCTIONS
-- ============================================================================

DELIMITER $$

-- ---------------------------------------------------------------------------
-- fn_calc_percentage : marks -> percentage, rounded to 2 places, clamped 0-100
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_calc_percentage $$
CREATE FUNCTION fn_calc_percentage(p_marks DECIMAL(6,2), p_max INT)
RETURNS DECIMAL(5,2)
DETERMINISTIC
BEGIN
    -- The intermediate value is held in a wide DECIMAL so that an absurd
    -- input (999 out of 75 = 1332%) is clamped instead of overflowing.
    DECLARE v_raw DECIMAL(12,2);
    DECLARE v_pct DECIMAL(5,2);

    IF p_max IS NULL OR p_max = 0 THEN
        RETURN 0.00;
    END IF;

    SET v_raw = ROUND((p_marks * 100.0) / p_max, 2);

    IF v_raw < 0   THEN SET v_raw = 0;   END IF;
    IF v_raw > 100 THEN SET v_raw = 100; END IF;

    SET v_pct = v_raw;
    RETURN v_pct;
END $$

-- ---------------------------------------------------------------------------
-- fn_get_grade : percentage -> letter grade
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_get_grade $$
CREATE FUNCTION fn_get_grade(p_pct DECIMAL(5,2))
RETURNS VARCHAR(2)
DETERMINISTIC
BEGIN
    RETURN CASE
        WHEN p_pct >= 90 THEN 'A+'
        WHEN p_pct >= 80 THEN 'A'
        WHEN p_pct >= 70 THEN 'B+'
        WHEN p_pct >= 60 THEN 'B'
        WHEN p_pct >= 50 THEN 'C'
        WHEN p_pct >= 40 THEN 'D'
        ELSE 'F'
    END;
END $$

-- ---------------------------------------------------------------------------
-- fn_get_rank : position of one result inside its exam
--    Ties share a rank (two students on 85% are both rank 2).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_get_rank $$
CREATE FUNCTION fn_get_rank(p_result_id INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_exam INT;
    DECLARE v_pct  DECIMAL(5,2);
    DECLARE v_rank INT;

    SELECT exam_id, percentage INTO v_exam, v_pct
      FROM results WHERE result_id = p_result_id;

    IF v_exam IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT COUNT(*) + 1 INTO v_rank
      FROM results
     WHERE exam_id = v_exam
       AND percentage > v_pct;

    RETURN v_rank;
END $$

DELIMITER ;

-- ============================================================================
--  TRIGGERS
-- ============================================================================

DELIMITER $$

-- ---------------------------------------------------------------------------
-- trg_results_bi : BEFORE INSERT
--   Fills percentage, grade and pass/fail automatically.
--   Rejects marks greater than the paper's maximum.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_results_bi $$
CREATE TRIGGER trg_results_bi
BEFORE INSERT ON results
FOR EACH ROW
BEGIN
    DECLARE v_max INT;

    SELECT max_marks INTO v_max FROM exams WHERE exam_id = NEW.exam_id;

    IF v_max IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Result rejected: that exam does not exist.';
    END IF;

    IF NEW.marks_obtained > v_max THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Result rejected: marks cannot exceed the maximum for this paper.';
    END IF;

    SET NEW.percentage    = fn_calc_percentage(NEW.marks_obtained, v_max);
    SET NEW.grade         = fn_get_grade(NEW.percentage);
    SET NEW.result_status = IF(NEW.percentage >= 40, 'PASS', 'FAIL');
END $$

-- ---------------------------------------------------------------------------
-- trg_results_bu : BEFORE UPDATE
--   Any change to the marks recomputes the percentage and the grade.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_results_bu $$
CREATE TRIGGER trg_results_bu
BEFORE UPDATE ON results
FOR EACH ROW
BEGIN
    DECLARE v_max INT;

    SELECT max_marks INTO v_max FROM exams WHERE exam_id = NEW.exam_id;

    IF NEW.marks_obtained > v_max THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Update rejected: marks cannot exceed the maximum for this paper.';
    END IF;

    SET NEW.percentage    = fn_calc_percentage(NEW.marks_obtained, v_max);
    SET NEW.grade         = fn_get_grade(NEW.percentage);
    SET NEW.result_status = IF(NEW.percentage >= 40, 'PASS', 'FAIL');
END $$

-- ---------------------------------------------------------------------------
-- trg_results_audit : AFTER INSERT / UPDATE / DELETE
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_results_ai $$
CREATE TRIGGER trg_results_ai
AFTER INSERT ON results
FOR EACH ROW
BEGIN
    INSERT INTO result_audit (result_id, action, old_marks, new_marks, changed_by)
    VALUES (NEW.result_id, 'INSERT', NULL, NEW.marks_obtained, NEW.entered_by);
END $$

DROP TRIGGER IF EXISTS trg_results_au $$
CREATE TRIGGER trg_results_au
AFTER UPDATE ON results
FOR EACH ROW
BEGIN
    INSERT INTO result_audit (result_id, action, old_marks, new_marks, changed_by)
    VALUES (NEW.result_id, 'UPDATE', OLD.marks_obtained, NEW.marks_obtained, NEW.entered_by);
END $$

DROP TRIGGER IF EXISTS trg_results_ad $$
CREATE TRIGGER trg_results_ad
AFTER DELETE ON results
FOR EACH ROW
BEGIN
    INSERT INTO result_audit (result_id, action, old_marks, new_marks, changed_by)
    VALUES (OLD.result_id, 'DELETE', OLD.marks_obtained, NULL, OLD.entered_by);
END $$

DELIMITER ;

-- ============================================================================
--  STORED PROCEDURES
-- ============================================================================

DELIMITER $$

-- ---------------------------------------------------------------------------
-- sp_generate_result : enter one student's marks and produce the result
--   Returns the new result id, or an error message.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_generate_result $$
CREATE PROCEDURE sp_generate_result(
    IN  p_student_id INT,
    IN  p_exam_id    INT,
    IN  p_marks      DECIMAL(6,2),
    IN  p_entered_by VARCHAR(50),
    OUT p_result_id  INT,
    OUT p_message    VARCHAR(200)
)
BEGIN
    DECLARE v_exists INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 @errmsg = MESSAGE_TEXT;
        SET p_result_id = NULL;
        SET p_message = CONCAT('Rejected: ', @errmsg);
    END;

    SELECT COUNT(*) INTO v_exists
      FROM results WHERE student_id = p_student_id AND exam_id = p_exam_id;

    IF v_exists > 0 THEN
        SET p_result_id = NULL;
        SET p_message = 'A result already exists for this student in this exam.';
    ELSE
        INSERT INTO results (student_id, exam_id, marks_obtained, entered_by)
        VALUES (p_student_id, p_exam_id, p_marks, p_entered_by);

        SET p_result_id = LAST_INSERT_ID();
        SET p_message = 'Result generated successfully.';
    END IF;
END $$

-- ---------------------------------------------------------------------------
-- sp_generate_exam_results : generate results for a whole class in one call
--   Marks arrive as a comma-separated list of "student_id:marks".
--   Uses a cursor, so one bad row does not stop the batch.
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_generate_exam_results $$
CREATE PROCEDURE sp_generate_exam_results(
    IN  p_exam_id    INT,
    IN  p_data       TEXT,
    IN  p_entered_by VARCHAR(50),
    OUT p_inserted   INT,
    OUT p_skipped    INT
)
BEGIN
    DECLARE v_done     INT DEFAULT 0;
    DECLARE v_entry    VARCHAR(50);
    DECLARE v_sid      INT;
    DECLARE v_marks    DECIMAL(6,2);
    DECLARE v_tot      INT DEFAULT 0;
    DECLARE v_pos      INT;

    -- Split "1:68,2:71" into one row per entry.
    -- The inner SUBSTRING_INDEX takes the first n items, the outer one with
    -- -1 keeps only the last of those, which is the nth item itself.
    DECLARE cur CURSOR FOR
        SELECT TRIM(SUBSTRING_INDEX(SUBSTRING_INDEX(p_data, ',', seq.n), ',', -1))
          FROM (SELECT 1 n UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
                UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10
                UNION ALL SELECT 11 UNION ALL SELECT 12 UNION ALL SELECT 13
                UNION ALL SELECT 14 UNION ALL SELECT 15 UNION ALL SELECT 16
                UNION ALL SELECT 17 UNION ALL SELECT 18 UNION ALL SELECT 19
                UNION ALL SELECT 20) seq
         WHERE seq.n <= 1 + LENGTH(p_data) - LENGTH(REPLACE(p_data, ',', ''));

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    SET p_inserted = 0;
    SET p_skipped  = 0;

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_entry;
        IF v_done THEN
            LEAVE read_loop;
        END IF;

        SET v_pos = LOCATE(':', v_entry);
        IF v_pos > 0 THEN
            SET v_sid   = CAST(SUBSTRING(v_entry, 1, v_pos - 1) AS UNSIGNED);
            SET v_marks = CAST(SUBSTRING(v_entry, v_pos + 1) AS DECIMAL(6,2));

            BEGIN
                DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
                BEGIN
                    SET p_skipped = p_skipped + 1;
                END;

                INSERT INTO results (student_id, exam_id, marks_obtained, entered_by)
                VALUES (v_sid, p_exam_id, v_marks, p_entered_by);
                SET p_inserted = p_inserted + 1;
            END;
        ELSE
            SET p_skipped = p_skipped + 1;
        END IF;
    END LOOP;
    CLOSE cur;
END $$

-- ---------------------------------------------------------------------------
-- sp_merit_list : ranked merit list for one exam
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_merit_list $$
CREATE PROCEDURE sp_merit_list(IN p_exam_id INT)
BEGIN
    SELECT RANK() OVER (ORDER BY r.percentage DESC) AS rank_no,
           s.roll_no,
           s.full_name,
           r.marks_obtained,
           e.max_marks,
           r.percentage,
           r.grade,
           r.result_status
      FROM results  r
      JOIN students s ON s.student_id = r.student_id
      JOIN exams    e ON e.exam_id    = r.exam_id
     WHERE r.exam_id = p_exam_id
     ORDER BY r.percentage DESC, s.roll_no;
END $$

-- ---------------------------------------------------------------------------
-- sp_student_report : every exam one student has taken, with grade and rank
-- ---------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_student_report $$
CREATE PROCEDURE sp_student_report(IN p_student_id INT)
BEGIN
    SELECT e.exam_name,
           e.subject,
           r.marks_obtained,
           e.max_marks,
           r.percentage,
           r.grade,
           r.result_status,
           (SELECT COUNT(*) + 1 FROM results r2
             WHERE r2.exam_id = r.exam_id AND r2.percentage > r.percentage) AS rank_no
      FROM results r
      JOIN exams   e ON e.exam_id = r.exam_id
     WHERE r.student_id = p_student_id
     ORDER BY e.exam_date DESC;
END $$

DELIMITER ;

-- ============================================================================
--  VIEWS
-- ============================================================================

CREATE OR REPLACE VIEW v_result_summary AS
SELECT r.result_id,
       s.student_id,
       s.roll_no,
       s.full_name,
       e.exam_id,
       e.exam_name,
       e.subject,
       e.max_marks,
       r.marks_obtained,
       r.percentage,
       r.grade,
       r.result_status,
       RANK() OVER (PARTITION BY r.exam_id ORDER BY r.percentage DESC) AS rank_no,
       r.created_at
  FROM results  r
  JOIN students s ON s.student_id = r.student_id
  JOIN exams    e ON e.exam_id    = r.exam_id;

CREATE OR REPLACE VIEW v_exam_summary AS
SELECT e.exam_id,
       e.exam_name,
       e.subject,
       e.max_marks,
       COUNT(r.result_id)                        AS students_appeared,
       ROUND(AVG(r.percentage), 2)               AS average_pct,
       MAX(r.percentage)                         AS highest_pct,
       MIN(r.percentage)                         AS lowest_pct,
       SUM(IF(r.result_status = 'PASS', 1, 0))   AS passed,
       SUM(IF(r.result_status = 'FAIL', 1, 0))   AS failed
  FROM exams e
  LEFT JOIN results r ON r.exam_id = e.exam_id
 GROUP BY e.exam_id, e.exam_name, e.subject, e.max_marks;

CREATE OR REPLACE VIEW v_grade_distribution AS
SELECT exam_id,
       grade,
       COUNT(*) AS students
  FROM results
 GROUP BY exam_id, grade;

-- ============================================================================
--  EXTENSION OBJECTS  (added for the analytics + editing features)
-- ============================================================================

DELIMITER $$

-- fn_grade_points : turn a letter grade into grade points, for the GPA
DROP FUNCTION IF EXISTS fn_grade_points $$
CREATE FUNCTION fn_grade_points(p_grade VARCHAR(2))
RETURNS DECIMAL(3,1)
DETERMINISTIC
BEGIN
    RETURN CASE p_grade
             WHEN 'A+' THEN 10.0
             WHEN 'A'  THEN 9.0
             WHEN 'B+' THEN 8.0
             WHEN 'B'  THEN 7.0
             WHEN 'C'  THEN 6.0
             WHEN 'D'  THEN 5.0
             ELSE 0.0
           END;
END $$

-- fn_class_topper : roll number of the highest scorer in one exam
DROP FUNCTION IF EXISTS fn_class_topper $$
CREATE FUNCTION fn_class_topper(p_exam_id INT)
RETURNS VARCHAR(20)
READS SQL DATA
BEGIN
    DECLARE v_roll VARCHAR(20);
    SELECT s.roll_no INTO v_roll
      FROM results r JOIN students s ON s.student_id = r.student_id
     WHERE r.exam_id = p_exam_id
     ORDER BY r.percentage DESC, r.marks_obtained DESC
     LIMIT 1;
    RETURN v_roll;
END $$

-- sp_class_statistics : one row of statistics for an exam
DROP PROCEDURE IF EXISTS sp_class_statistics $$
CREATE PROCEDURE sp_class_statistics(IN p_exam_id INT)
BEGIN
    DECLARE v_n    INT DEFAULT 0;
    DECLARE v_rows INT DEFAULT 0;
    DECLARE v_low  INT DEFAULT 0;
    DECLARE v_median DECIMAL(6,2) DEFAULT NULL;

    SELECT COUNT(*) INTO v_n FROM results WHERE exam_id = p_exam_id;

    IF v_n > 0 THEN
        SET v_rows = 2 - (v_n % 2);
        SET v_low  = (v_n - v_rows) DIV 2;
        SELECT ROUND(AVG(percentage), 2) INTO v_median
          FROM (SELECT percentage FROM results
                 WHERE exam_id = p_exam_id
                 ORDER BY percentage
                 LIMIT v_low, v_rows) t;
    END IF;

    SELECT e.exam_id,
           e.exam_name,
           e.max_marks,
           v_n                                            AS appeared,
           ROUND(AVG(r.percentage), 2)                    AS average_pct,
           v_median                                       AS median_pct,
           ROUND(STDDEV(r.percentage), 2)                 AS std_dev,
           MAX(r.percentage)                              AS highest_pct,
           MIN(r.percentage)                              AS lowest_pct,
           SUM(IF(r.result_status = 'PASS', 1, 0))        AS passed,
           SUM(IF(r.result_status = 'FAIL', 1, 0))        AS failed,
           ROUND(100 * SUM(IF(r.result_status='PASS',1,0))
                 / NULLIF(v_n, 0), 2)                     AS pass_rate,
           fn_class_topper(p_exam_id)                     AS topper_roll
      FROM exams e
      LEFT JOIN results r ON r.exam_id = e.exam_id
     WHERE e.exam_id = p_exam_id
     GROUP BY e.exam_id, e.exam_name, e.max_marks;
END $$

-- sp_update_marks : correct one result; the AFTER UPDATE trigger redoes the maths
DROP PROCEDURE IF EXISTS sp_update_marks $$
CREATE PROCEDURE sp_update_marks(IN p_result_id INT,
                                 IN p_new_marks DECIMAL(6,2),
                                 IN p_who VARCHAR(50))
BEGIN
    DECLARE v_max  INT;
    DECLARE v_old  DECIMAL(6,2);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    SELECT marks_obtained INTO v_old FROM results WHERE result_id = p_result_id;

    IF v_old IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'No such result.';
    END IF;

    SELECT e.max_marks INTO v_max
      FROM results r JOIN exams e ON e.exam_id = r.exam_id
     WHERE r.result_id = p_result_id;

    IF p_new_marks < 0 OR p_new_marks > v_max THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Marks must be between 0 and the paper maximum.';
    END IF;

    UPDATE results
       SET marks_obtained = p_new_marks,
           entered_by     = p_who
     WHERE result_id = p_result_id;
    COMMIT;
END $$

-- sp_delete_result : remove one result, leaving the delete in the audit trail
DROP PROCEDURE IF EXISTS sp_delete_result $$
CREATE PROCEDURE sp_delete_result(IN p_result_id INT, IN p_who VARCHAR(50))
BEGIN
    DECLARE v_n INT DEFAULT 0;
    SELECT COUNT(*) INTO v_n FROM results WHERE result_id = p_result_id;
    IF v_n = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No such result.';
    END IF;
    DELETE FROM results WHERE result_id = p_result_id;
END $$

DELIMITER ;

-- ---------------------------------------------------------------------------
--  v_student_totals : every student's whole record, with GPA and overall rank
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_student_totals AS
SELECT t.*,
       RANK() OVER (ORDER BY t.overall_pct DESC) AS overall_rank
  FROM (SELECT s.student_id,
               s.roll_no,
               s.full_name,
               s.program,
               COUNT(r.result_id)                                  AS exams_taken,
               ROUND(SUM(r.marks_obtained), 2)                     AS total_marks,
               SUM(e.max_marks)                                    AS total_max,
               ROUND(100 * SUM(r.marks_obtained)
                     / NULLIF(SUM(e.max_marks), 0), 2)             AS overall_pct,
               ROUND(AVG(fn_grade_points(r.grade)), 2)             AS gpa,
               SUM(r.result_status = 'PASS')                       AS passed,
               SUM(r.result_status = 'FAIL')                       AS failed
          FROM students s
          LEFT JOIN results r ON r.student_id = s.student_id
          LEFT JOIN exams   e ON e.exam_id    = r.exam_id
         GROUP BY s.student_id, s.roll_no, s.full_name, s.program) t;

-- ---------------------------------------------------------------------------
--  v_subject_summary : results rolled up by subject
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_subject_summary AS
SELECT e.subject,
       COUNT(DISTINCT e.exam_id)                       AS exams,
       COUNT(r.result_id)                              AS results_entered,
       ROUND(AVG(r.percentage), 2)                     AS average_pct,
       MAX(r.percentage)                               AS best_pct,
       SUM(IF(r.result_status = 'PASS', 1, 0))         AS passed,
       SUM(IF(r.result_status = 'FAIL', 1, 0))         AS failed,
       ROUND(100 * SUM(IF(r.result_status='PASS',1,0))
             / NULLIF(COUNT(r.result_id), 0), 2)       AS pass_rate
  FROM exams e
  LEFT JOIN results r ON r.exam_id = e.exam_id
 GROUP BY e.subject;
