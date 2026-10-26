-- ============================================================================
--  PROJECT : Online Examination Result System
--  FILE    : 02_seed_data.sql
-- ============================================================================
USE result_system;

-- ------------------------------------------------------------------ students
INSERT INTO students (roll_no, full_name, email, program, semester) VALUES
('26MCI10246', 'Puneet Gupta',   'puneet.gupta@examai.edu',   'MCA', 1),
('26MCI10247', 'Aditya Sharma',  'aditya.sharma@examai.edu',  'MCA', 1),
('26MCI10248', 'Neha Kaur',      'neha.kaur@examai.edu',      'MCA', 1),
('26MCI10249', 'Karan Malhotra', 'karan.malhotra@examai.edu', 'MCA', 1),
('26MCI10250', 'Simran Bedi',    'simran.bedi@examai.edu',    'MCA', 1),
('26MCI10251', 'Rohit Verma',    'rohit.verma@examai.edu',    'MCA', 1),
('26MCI10252', 'Ananya Nair',    'ananya.nair@examai.edu',    'MCA', 1),
('26MCI10253', 'Vikram Singh',   'vikram.singh@examai.edu',   'MCA', 1);

-- --------------------------------------------------------------------- exams
INSERT INTO exams (exam_name, subject, max_marks, exam_date, exam_type) VALUES
('DBMS Mid Term',        'Database Management Systems', 100, '2026-09-15', 'THEORY'),
('Java Mid Term',        'Java Programming',            100, '2026-09-18', 'THEORY'),
('DBMS Practical',       'Database Management Systems', 50,  '2026-09-22', 'PRACTICAL'),
('DAA Mid Term',         'Design and Analysis of Algorithms', 75, '2026-09-25', 'THEORY');

-- ------------------------------------------------------------------- results
-- Inserted the way the application would: only the marks are supplied.
-- The trigger works out the percentage, the grade and pass/fail.
INSERT INTO results (student_id, exam_id, marks_obtained, entered_by) VALUES
(1, 1, 87, 'mandeep.singh'),
(2, 1, 92, 'mandeep.singh'),
(3, 1, 78, 'mandeep.singh'),
(4, 1, 45, 'mandeep.singh'),
(5, 1, 66, 'mandeep.singh'),
(6, 1, 33, 'mandeep.singh'),
(7, 1, 95, 'mandeep.singh'),
(8, 1, 58, 'mandeep.singh');

INSERT INTO results (student_id, exam_id, marks_obtained, entered_by) VALUES
(1, 2, 74, 'rakesh.verma'),
(2, 2, 81, 'rakesh.verma'),
(3, 2, 67, 'rakesh.verma'),
(5, 2, 90, 'rakesh.verma'),
(7, 2, 55, 'rakesh.verma');

INSERT INTO results (student_id, exam_id, marks_obtained, entered_by) VALUES
(1, 3, 41, 'mandeep.singh'),
(2, 3, 46, 'mandeep.singh'),
(4, 3, 28, 'mandeep.singh'),
(6, 3, 35, 'mandeep.singh');

INSERT INTO results (student_id, exam_id, marks_obtained, entered_by) VALUES
(1, 4, 68, 'mandeep.singh'),
(2, 4, 71, 'mandeep.singh'),
(5, 4, 52, 'mandeep.singh'),
(6, 4, 30, 'mandeep.singh'),
(7, 4, 74, 'mandeep.singh'),
(8, 4, 60, 'mandeep.singh');

SELECT 'Seeded.' AS status,
       (SELECT COUNT(*) FROM students) AS students,
       (SELECT COUNT(*) FROM exams)    AS exams,
       (SELECT COUNT(*) FROM results)  AS results;
