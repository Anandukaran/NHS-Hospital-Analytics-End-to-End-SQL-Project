/*
=============================================================================
 NHS Hospital Analytics  |  End-to-End Exploratory & Advanced Data Analysis
=============================================================================
 Dataset : Patient hospital visits (star schema, 'gold' schema)
           fact_visits  +  dim_patients / providers / departments /
           diagnoses / procedures / insurance / cities
 Engine  : Microsoft SQL Server (T-SQL)
 Author  : Anandu Karunakaran

 Notes on the domain measures used throughout:
   - "visit_cost" (a visit's billed amount) = treatment_cost + medication_cost.
     This is the primary revenue/value measure, analogous to sales_amount in a
     retail model.
   - insurance_coverage and room charges are analysed separately.
   - Grain of fact_visits = ONE VISIT (one row per attendance).

 Structure:
   STAGE 1  Data Understanding
   STAGE 2  Dimension Exploration
   STAGE 3  Date Exploration
   STAGE 4  Measures (KPI summary)
   STAGE 5  Magnitude Analysis
   STAGE 6  Ranking Analysis
   STAGE 7  Advanced Analytics
            7a Change-over-time     7b Cumulative/moving avg
            7c Performance (LAG)    7d Part-to-whole
            7e Segmentation
   STAGE 8  Reporting Views (patients, providers, departments)
=============================================================================
*/

USE HospitalAnalytics;
GO

/* ===========================================================================
   STAGE 1 - DATA UNDERSTANDING
   Inspect the tables and columns available in the model.
   =========================================================================*/

-- List all tables
SELECT * FROM INFORMATION_SCHEMA.TABLES;

-- Inspect columns of the fact table
SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'fact_visits';

-- Inspect columns of the patient dimension
SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'dim_patients';


/* ===========================================================================
   STAGE 2 - DIMENSION EXPLORATION
   Understand the distinct members of each dimension.
   =========================================================================*/

-- Departments, diagnoses, procedures, insurers, referral & service types
SELECT DISTINCT department      FROM gold.dim_departments ORDER BY department;
SELECT DISTINCT diagnosis       FROM gold.dim_diagnoses   ORDER BY diagnosis;
SELECT DISTINCT procedure_name  FROM gold.dim_procedures  ORDER BY procedure_name;
SELECT DISTINCT insurance_provider FROM gold.dim_insurance;
SELECT DISTINCT service_type    FROM gold.fact_visits     ORDER BY service_type;
SELECT DISTINCT referral_source FROM gold.fact_visits     ORDER BY referral_source;

-- Geography: regions and the cities within them
SELECT region, COUNT(*) AS cities_in_region
FROM gold.dim_cities
GROUP BY region
ORDER BY region;

-- Patient demographics available for segmentation
SELECT DISTINCT gender FROM gold.dim_patients;
SELECT DISTINCT race   FROM gold.dim_patients ORDER BY race;

-- Provider roster
SELECT provider_id, provider_name, gender, nationality, age
FROM gold.dim_providers
ORDER BY provider_name;


/* ===========================================================================
   STAGE 3 - DATE EXPLORATION
   Establish the time window and demographic age span.
   =========================================================================*/

-- First & last visit, and the span of activity in months
SELECT MIN(date_of_visit) AS first_visit,
       MAX(date_of_visit) AS last_visit,
       DATEDIFF(MONTH, MIN(date_of_visit), MAX(date_of_visit)) AS activity_span_months
FROM gold.fact_visits;

-- Youngest & oldest patients
SELECT MIN(age) AS youngest_patient,
       MAX(age) AS oldest_patient,
       AVG(age) AS average_age
FROM gold.dim_patients;

-- Are there any admissions recorded, and over what window? (inpatients only)
SELECT MIN(admitted_date) AS first_admission,
       MAX(discharge_date) AS last_discharge,
       COUNT(admitted_date) AS admissions_with_dates
FROM gold.fact_visits;


/* ===========================================================================
   STAGE 4 - MEASURES EXPLORATION
   Headline totals, then combined into a single KPI summary table.
   =========================================================================*/

SELECT SUM(treatment_cost + medication_cost) AS total_billed FROM gold.fact_visits;
SELECT COUNT(*)                    AS total_visits             FROM gold.fact_visits;
SELECT COUNT(DISTINCT patient_id)  AS total_patients_seen      FROM gold.fact_visits;
SELECT AVG(treatment_cost + medication_cost) AS avg_visit_cost FROM gold.fact_visits;
SELECT AVG(CAST(satisfaction_score AS FLOAT)) AS avg_satisfaction FROM gold.fact_visits;

-- Average length of stay (LOS) for inpatients that have both dates
SELECT AVG(DATEDIFF(DAY, admitted_date, discharge_date)) AS avg_length_of_stay_days
FROM gold.fact_visits
WHERE admitted_date IS NOT NULL AND discharge_date IS NOT NULL;

-- One consolidated KPI table (UNION ALL of single-value measures)
SELECT 'Total Visits'          AS measure_name, CAST(COUNT(*) AS DECIMAL(18,2)) AS measure_value FROM gold.fact_visits
UNION ALL SELECT 'Total Patients Seen',   CAST(COUNT(DISTINCT patient_id) AS DECIMAL(18,2)) FROM gold.fact_visits
UNION ALL SELECT 'Total Billed (Treat+Med)', CAST(SUM(treatment_cost + medication_cost) AS DECIMAL(18,2)) FROM gold.fact_visits
UNION ALL SELECT 'Avg Visit Cost',        CAST(AVG(treatment_cost + medication_cost) AS DECIMAL(18,2)) FROM gold.fact_visits
UNION ALL SELECT 'Avg Satisfaction (1-10)', CAST(AVG(CAST(satisfaction_score AS FLOAT)) AS DECIMAL(18,2)) FROM gold.fact_visits
UNION ALL SELECT 'Emergency Visits',      CAST(SUM(CASE WHEN emergency_visit='Yes' THEN 1 ELSE 0 END) AS DECIMAL(18,2)) FROM gold.fact_visits
UNION ALL SELECT 'Pending Payments',      CAST(SUM(CASE WHEN payment_status='Pending' THEN 1 ELSE 0 END) AS DECIMAL(18,2)) FROM gold.fact_visits;


/* ===========================================================================
   STAGE 5 - MAGNITUDE ANALYSIS
   Break the measures down across each dimension.
   =========================================================================*/

-- Visits & billed value by department
SELECT d.department,
       COUNT(*)                                  AS total_visits,
       SUM(f.treatment_cost + f.medication_cost) AS total_billed,
       AVG(CAST(f.satisfaction_score AS FLOAT))  AS avg_satisfaction
FROM gold.fact_visits f
LEFT JOIN gold.dim_departments d ON f.department_id = d.department_id
GROUP BY d.department
ORDER BY total_billed DESC;

-- Visits & billed value by diagnosis
SELECT dg.diagnosis,
       COUNT(*)                                  AS total_visits,
       SUM(f.treatment_cost + f.medication_cost) AS total_billed
FROM gold.fact_visits f
LEFT JOIN gold.dim_diagnoses dg ON f.diagnosis_id = dg.diagnosis_id
GROUP BY dg.diagnosis
ORDER BY total_visits DESC;

-- Visits by procedure
SELECT p.procedure_name, COUNT(*) AS total_visits
FROM gold.fact_visits f
LEFT JOIN gold.dim_procedures p ON f.procedure_id = p.procedure_id
GROUP BY p.procedure_name
ORDER BY total_visits DESC;

-- Service-type mix (Outpatient / Inpatient / Emergency)
SELECT service_type,
       COUNT(*)                                  AS total_visits,
       SUM(treatment_cost + medication_cost)     AS total_billed,
       AVG(CAST(satisfaction_score AS FLOAT))    AS avg_satisfaction
FROM gold.fact_visits
GROUP BY service_type
ORDER BY total_visits DESC;

-- Geography: visits & billed value by region
SELECT c.region,
       COUNT(*)                                  AS total_visits,
       SUM(f.treatment_cost + f.medication_cost) AS total_billed
FROM gold.fact_visits f
LEFT JOIN gold.dim_patients pt ON f.patient_id = pt.patient_id
LEFT JOIN gold.dim_cities   c  ON pt.city_id  = c.city_id
GROUP BY c.region
ORDER BY total_billed DESC;

-- Demographics: visits by patient gender and by race
SELECT pt.gender, COUNT(*) AS total_visits
FROM gold.fact_visits f
LEFT JOIN gold.dim_patients pt ON f.patient_id = pt.patient_id
GROUP BY pt.gender;

SELECT pt.race, COUNT(*) AS total_visits
FROM gold.fact_visits f
LEFT JOIN gold.dim_patients pt ON f.patient_id = pt.patient_id
GROUP BY pt.race
ORDER BY total_visits DESC;

-- Payer mix: visits & billed value by insurance provider
SELECT i.insurance_provider,
       COUNT(*)                                  AS total_visits,
       SUM(f.treatment_cost + f.medication_cost) AS total_billed,
       AVG(f.insurance_coverage)                 AS avg_coverage
FROM gold.fact_visits f
LEFT JOIN gold.dim_insurance i ON f.insurance_id = i.insurance_id
GROUP BY i.insurance_provider
ORDER BY total_billed DESC;

-- Operational flags: referral source, emergency rate, payment status
SELECT referral_source, COUNT(*) AS total_visits
FROM gold.fact_visits GROUP BY referral_source ORDER BY total_visits DESC;

SELECT payment_status,
       COUNT(*) AS total_visits,
       CONCAT(CAST(ROUND(COUNT(*)*100.0/SUM(COUNT(*)) OVER (),1) AS DECIMAL(5,1)),' %') AS share
FROM gold.fact_visits GROUP BY payment_status;


/* ===========================================================================
   STAGE 6 - RANKING ANALYSIS
   Best / worst performers, shown with both TOP and window functions.
   =========================================================================*/

-- Top 3 diagnoses by billed value
SELECT TOP 3 dg.diagnosis,
       SUM(f.treatment_cost + f.medication_cost) AS total_billed
FROM gold.fact_visits f
LEFT JOIN gold.dim_diagnoses dg ON f.diagnosis_id = dg.diagnosis_id
GROUP BY dg.diagnosis
ORDER BY total_billed DESC;

-- Same result via window function (RANK) - demonstrates equivalence
SELECT * FROM (
    SELECT dg.diagnosis,
           SUM(f.treatment_cost + f.medication_cost) AS total_billed,
           RANK() OVER (ORDER BY SUM(f.treatment_cost + f.medication_cost) DESC) AS rnk
    FROM gold.fact_visits f
    LEFT JOIN gold.dim_diagnoses dg ON f.diagnosis_id = dg.diagnosis_id
    GROUP BY dg.diagnosis
) t
WHERE rnk <= 3;

-- Provider league table: volume, revenue, satisfaction, emergency rate
SELECT pr.provider_name,
       COUNT(*)                                  AS total_visits,
       SUM(f.treatment_cost + f.medication_cost) AS total_billed,
       AVG(CAST(f.satisfaction_score AS FLOAT))  AS avg_satisfaction,
       CAST(AVG(CASE WHEN f.emergency_visit='Yes' THEN 1.0 ELSE 0 END)*100 AS DECIMAL(5,1)) AS emergency_pct
FROM gold.fact_visits f
LEFT JOIN gold.dim_providers pr ON f.provider_id = pr.provider_id
GROUP BY pr.provider_name
ORDER BY total_visits DESC;

-- Highest & lowest average-satisfaction providers (min 100 visits)
SELECT TOP 1 pr.provider_name, AVG(CAST(f.satisfaction_score AS FLOAT)) AS avg_sat, 'Best' AS flag
FROM gold.fact_visits f LEFT JOIN gold.dim_providers pr ON f.provider_id = pr.provider_id
GROUP BY pr.provider_name HAVING COUNT(*) >= 100 ORDER BY avg_sat DESC;

SELECT TOP 1 pr.provider_name, AVG(CAST(f.satisfaction_score AS FLOAT)) AS avg_sat, 'Worst' AS flag
FROM gold.fact_visits f LEFT JOIN gold.dim_providers pr ON f.provider_id = pr.provider_id
GROUP BY pr.provider_name HAVING COUNT(*) >= 100 ORDER BY avg_sat ASC;

-- Top 10 cities by patient volume
SELECT TOP 10 c.city, c.region, COUNT(*) AS total_visits
FROM gold.fact_visits f
LEFT JOIN gold.dim_patients pt ON f.patient_id = pt.patient_id
LEFT JOIN gold.dim_cities   c  ON pt.city_id  = c.city_id
GROUP BY c.city, c.region
ORDER BY total_visits DESC;


/* ===========================================================================
   STAGE 7 - ADVANCED ANALYTICS
   =========================================================================*/

/* --- 7a  CHANGE OVER TIME ------------------------------------------------ */

-- Yearly trend
SELECT YEAR(date_of_visit) AS visit_year,
       COUNT(*)                                  AS total_visits,
       COUNT(DISTINCT patient_id)                AS patients,
       SUM(treatment_cost + medication_cost)     AS total_billed,
       AVG(CAST(satisfaction_score AS FLOAT))    AS avg_satisfaction
FROM gold.fact_visits
WHERE date_of_visit IS NOT NULL
GROUP BY YEAR(date_of_visit)
ORDER BY visit_year;

-- Monthly trend (year + month) - the main time series
SELECT DATETRUNC(MONTH, date_of_visit)           AS visit_month,
       COUNT(*)                                  AS total_visits,
       SUM(treatment_cost + medication_cost)     AS total_billed,
       AVG(CAST(satisfaction_score AS FLOAT))    AS avg_satisfaction
FROM gold.fact_visits
WHERE date_of_visit IS NOT NULL
GROUP BY DATETRUNC(MONTH, date_of_visit)
ORDER BY visit_month;

-- Seasonality: which calendar months are busiest (all years combined)
SELECT DATEPART(MONTH, date_of_visit)            AS month_no,
       DATENAME(MONTH, date_of_visit)            AS month_name,
       COUNT(*)                                  AS total_visits,
       SUM(treatment_cost + medication_cost)     AS total_billed
FROM gold.fact_visits
WHERE date_of_visit IS NOT NULL
GROUP BY DATEPART(MONTH, date_of_visit), DATENAME(MONTH, date_of_visit)
ORDER BY month_no;


/* --- 7b  CUMULATIVE & MOVING AVERAGE ------------------------------------- */

-- Running total of billed value and a 3-month moving average of visit cost
SELECT *,
       SUM(total_billed) OVER (ORDER BY visit_month)                                       AS running_total_billed,
       AVG(avg_cost)     OVER (ORDER BY visit_month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS moving_avg_3m_cost
FROM (
    SELECT DATETRUNC(MONTH, date_of_visit)                 AS visit_month,
           SUM(treatment_cost + medication_cost)           AS total_billed,
           AVG(CAST(treatment_cost + medication_cost AS FLOAT)) AS avg_cost
    FROM gold.fact_visits
    WHERE date_of_visit IS NOT NULL
    GROUP BY DATETRUNC(MONTH, date_of_visit)
) m
ORDER BY visit_month;


/* --- 7c  PERFORMANCE ANALYSIS (LAG / vs-average) ------------------------- */

-- Month-on-month change in billed value using LAG
WITH monthly AS (
    SELECT DATETRUNC(MONTH, date_of_visit)       AS visit_month,
           SUM(treatment_cost + medication_cost) AS total_billed
    FROM gold.fact_visits
    WHERE date_of_visit IS NOT NULL
    GROUP BY DATETRUNC(MONTH, date_of_visit)
)
SELECT visit_month,
       total_billed,
       LAG(total_billed) OVER (ORDER BY visit_month) AS prev_month_billed,
       total_billed - LAG(total_billed) OVER (ORDER BY visit_month) AS mom_change,
       CASE
           WHEN LAG(total_billed) OVER (ORDER BY visit_month) IS NULL THEN 'First Month'
           WHEN total_billed > LAG(total_billed) OVER (ORDER BY visit_month) THEN 'Up'
           WHEN total_billed < LAG(total_billed) OVER (ORDER BY visit_month) THEN 'Down'
           ELSE 'Flat'
       END AS trend
FROM monthly
ORDER BY visit_month;

-- Department revenue vs the average department revenue (benchmarking)
WITH dept_rev AS (
    SELECT d.department,
           SUM(f.treatment_cost + f.medication_cost) AS total_billed
    FROM gold.fact_visits f
    LEFT JOIN gold.dim_departments d ON f.department_id = d.department_id
    GROUP BY d.department
)
SELECT department,
       total_billed,
       AVG(total_billed) OVER ()                          AS avg_dept_billed,
       total_billed - AVG(total_billed) OVER ()           AS diff_from_avg,
       CASE WHEN total_billed > AVG(total_billed) OVER () THEN 'Above Average'
            WHEN total_billed < AVG(total_billed) OVER () THEN 'Below Average'
            ELSE 'Average' END                            AS performance
FROM dept_rev
ORDER BY total_billed DESC;


/* --- 7d  PART-TO-WHOLE --------------------------------------------------- */

-- Each department's share of total billed value
WITH dept AS (
    SELECT d.department, SUM(f.treatment_cost + f.medication_cost) AS total_billed
    FROM gold.fact_visits f
    LEFT JOIN gold.dim_departments d ON f.department_id = d.department_id
    GROUP BY d.department
)
SELECT department,
       total_billed,
       SUM(total_billed) OVER () AS overall_billed,
       CONCAT(CAST(ROUND(total_billed*100.0/SUM(total_billed) OVER (),2) AS DECIMAL(5,2)),' %') AS pct_of_total
FROM dept
ORDER BY total_billed DESC;

-- Service-type share of visits
WITH svc AS (
    SELECT service_type, COUNT(*) AS total_visits FROM gold.fact_visits GROUP BY service_type
)
SELECT service_type,
       total_visits,
       CONCAT(CAST(ROUND(total_visits*100.0/SUM(total_visits) OVER (),2) AS DECIMAL(5,2)),' %') AS pct_of_visits
FROM svc
ORDER BY total_visits DESC;


/* --- 7e  SEGMENTATION ---------------------------------------------------- */

-- Segment visits into billed-cost bands
WITH bands AS (
    SELECT visit_id,
           CASE
               WHEN treatment_cost + medication_cost < 250  THEN 'A. Under 250'
               WHEN treatment_cost + medication_cost < 500  THEN 'B. 250-499'
               WHEN treatment_cost + medication_cost < 750  THEN 'C. 500-749'
               WHEN treatment_cost + medication_cost < 1000 THEN 'D. 750-999'
               ELSE 'E. 1000+'
           END AS cost_band
    FROM gold.fact_visits
)
SELECT cost_band, COUNT(*) AS visit_count
FROM bands
GROUP BY cost_band
ORDER BY cost_band;

-- Segment PATIENTS by lifetime spend across all their visits
--   High value : total spend >= 1500
--   Mid value  : 750 - 1499
--   Low value  : < 750
WITH patient_spend AS (
    SELECT patient_id,
           COUNT(*)                                  AS visits,
           SUM(treatment_cost + medication_cost)     AS total_spend
    FROM gold.fact_visits
    GROUP BY patient_id
)
SELECT CASE
           WHEN total_spend >= 1500 THEN 'High value'
           WHEN total_spend >= 750  THEN 'Mid value'
           ELSE 'Low value'
       END AS patient_segment,
       COUNT(*)          AS patient_count,
       SUM(total_spend)  AS segment_spend
FROM patient_spend
GROUP BY CASE
           WHEN total_spend >= 1500 THEN 'High value'
           WHEN total_spend >= 750  THEN 'Mid value'
           ELSE 'Low value'
         END
ORDER BY segment_spend DESC;

-- Age-group analysis: visits, avg cost and avg satisfaction by patient age band
WITH v AS (
    SELECT f.treatment_cost + f.medication_cost AS visit_cost,
           f.satisfaction_score,
           CASE
               WHEN pt.age < 30 THEN '18-29'
               WHEN pt.age < 40 THEN '30-39'
               WHEN pt.age < 50 THEN '40-49'
               WHEN pt.age < 60 THEN '50-59'
               ELSE '60+'
           END AS age_group
    FROM gold.fact_visits f
    LEFT JOIN gold.dim_patients pt ON f.patient_id = pt.patient_id
)
SELECT age_group,
       COUNT(*)                               AS total_visits,
       AVG(visit_cost)                        AS avg_visit_cost,
       AVG(CAST(satisfaction_score AS FLOAT)) AS avg_satisfaction
FROM v
GROUP BY age_group
ORDER BY age_group;


/* ===========================================================================
   STAGE 8 - REPORTING VIEWS
   Reusable, consolidated views that productionise the KPIs above.
   =========================================================================*/
GO
/* ---------------------------------------------------------------------------
   8.1  gold.report_patients
        One row per patient with lifetime metrics, recency and a value tier.
--------------------------------------------------------------------------- */
CREATE OR ALTER VIEW gold.report_patients AS
WITH base AS (
    SELECT f.visit_id, f.patient_id, f.date_of_visit,
           f.treatment_cost + f.medication_cost AS visit_cost,
           f.satisfaction_score, f.department_id, f.diagnosis_id,
           pt.patient_name, pt.gender, pt.age, pt.race
    FROM gold.fact_visits f
    LEFT JOIN gold.dim_patients pt ON f.patient_id = pt.patient_id
    WHERE f.date_of_visit IS NOT NULL
),
agg AS (
    SELECT patient_id, patient_name, gender, age, race,
           COUNT(*)                          AS total_visits,
           SUM(visit_cost)                   AS total_spend,
           AVG(CAST(satisfaction_score AS FLOAT)) AS avg_satisfaction,
           COUNT(DISTINCT department_id)     AS distinct_departments,
           COUNT(DISTINCT diagnosis_id)      AS distinct_diagnoses,
           MIN(date_of_visit)                AS first_visit,
           MAX(date_of_visit)                AS last_visit
    FROM base
    GROUP BY patient_id, patient_name, gender, age, race
)
SELECT patient_id, patient_name, gender, age,
       CASE WHEN age < 30 THEN '18-29'
            WHEN age < 40 THEN '30-39'
            WHEN age < 50 THEN '40-49'
            WHEN age < 60 THEN '50-59'
            ELSE '60+' END                    AS age_group,
       race,
       total_visits, total_spend, avg_satisfaction,
       distinct_departments, distinct_diagnoses,
       first_visit, last_visit,
       DATEDIFF(MONTH, last_visit, GETDATE()) AS recency_months,
       CASE WHEN total_visits = 0 THEN 0 ELSE total_spend / total_visits END AS avg_cost_per_visit,
       CASE WHEN total_spend >= 1500 THEN 'High value'
            WHEN total_spend >= 750  THEN 'Mid value'
            ELSE 'Low value' END              AS value_segment
FROM agg;
GO

/* ---------------------------------------------------------------------------
   8.2  gold.report_providers
        One row per provider with workload, revenue, quality and case-mix.
--------------------------------------------------------------------------- */
CREATE OR ALTER VIEW gold.report_providers AS
WITH base AS (
    SELECT f.provider_id, pr.provider_name, pr.nationality, pr.age AS provider_age,
           f.treatment_cost + f.medication_cost AS visit_cost,
           f.satisfaction_score, f.patient_id, f.emergency_visit, f.service_type,
           f.admitted_date, f.discharge_date, f.date_of_visit
    FROM gold.fact_visits f
    LEFT JOIN gold.dim_providers pr ON f.provider_id = pr.provider_id
)
SELECT provider_id, provider_name, nationality, provider_age,
       COUNT(*)                                   AS total_visits,
       COUNT(DISTINCT patient_id)                 AS unique_patients,
       SUM(visit_cost)                            AS total_billed,
       CASE WHEN COUNT(*)=0 THEN 0 ELSE SUM(visit_cost)/COUNT(*) END AS avg_billed_per_visit,
       CAST(AVG(CAST(satisfaction_score AS FLOAT)) AS DECIMAL(4,2)) AS avg_satisfaction,
       CAST(AVG(CASE WHEN emergency_visit='Yes' THEN 1.0 ELSE 0 END)*100 AS DECIMAL(5,1)) AS emergency_pct,
       SUM(CASE WHEN service_type='Inpatient' THEN 1 ELSE 0 END) AS inpatient_visits,
       AVG(CASE WHEN admitted_date IS NOT NULL AND discharge_date IS NOT NULL
                THEN DATEDIFF(DAY, admitted_date, discharge_date) END) AS avg_los_days,
       CASE
           WHEN AVG(CAST(satisfaction_score AS FLOAT)) >= 4.5 THEN 'High satisfaction'
           WHEN AVG(CAST(satisfaction_score AS FLOAT)) >= 3.0 THEN 'Mid satisfaction'
           ELSE 'Low satisfaction'
       END                                        AS quality_tier
FROM base
GROUP BY provider_id, provider_name, nationality, provider_age;
GO

/* ---------------------------------------------------------------------------
   8.3  gold.report_departments
        Department scorecard: demand, revenue, quality and payment risk.
--------------------------------------------------------------------------- */
CREATE OR ALTER VIEW gold.report_departments AS
SELECT d.department_id, d.department,
       COUNT(*)                                   AS total_visits,
       COUNT(DISTINCT f.patient_id)               AS unique_patients,
       SUM(f.treatment_cost + f.medication_cost)  AS total_billed,
       CASE WHEN COUNT(*)=0 THEN 0
            ELSE SUM(f.treatment_cost + f.medication_cost)/COUNT(*) END AS avg_billed_per_visit,
       CAST(AVG(CAST(f.satisfaction_score AS FLOAT)) AS DECIMAL(4,2))   AS avg_satisfaction,
       CAST(AVG(CASE WHEN f.emergency_visit='Yes' THEN 1.0 ELSE 0 END)*100 AS DECIMAL(5,1)) AS emergency_pct,
       CAST(AVG(CASE WHEN f.payment_status='Pending' THEN 1.0 ELSE 0 END)*100 AS DECIMAL(5,1)) AS pending_payment_pct,
       CONCAT(CAST(ROUND(SUM(f.treatment_cost + f.medication_cost)*100.0
              / SUM(SUM(f.treatment_cost + f.medication_cost)) OVER (),2) AS DECIMAL(5,2)),' %') AS pct_of_total_billed
FROM gold.fact_visits f
LEFT JOIN gold.dim_departments d ON f.department_id = d.department_id
GROUP BY d.department_id, d.department;
GO

-- Example reads of the finished views
SELECT TOP 20 * FROM gold.report_patients   ORDER BY total_spend DESC;
SELECT *        FROM gold.report_providers  ORDER BY total_visits DESC;
SELECT *        FROM gold.report_departments ORDER BY total_billed DESC;
GO
