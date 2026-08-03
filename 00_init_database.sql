/*
=============================================================================
 NHS Hospital Analytics  |  Database Initialisation & Data Load
=============================================================================
Script Purpose:
    Creates the 'HospitalAnalytics' data warehouse, a 'gold' schema, and a
    star-schema model (1 fact + 7 dimensions) describing patient hospital
    visits. Raw CSVs are landed into NVARCHAR staging tables, then cleaned
    and type-cast into the final typed tables.

    A two-step (stage -> clean -> load) pattern is used on purpose: the raw
    files contain empty strings, literal 'N/A' text, and US-format dates
    (m/d/yyyy). Loading straight into typed columns would fail, so staging
    lets us validate and convert safely with TRY_CONVERT / NULLIF.

WARNING:
    Running this script DROPS the entire 'HospitalAnalytics' database if it
    already exists. All data will be permanently deleted. Back up first.

BEFORE RUNNING:
    Update @data_path below to the folder that holds the 8 CSV files.
    The SQL Server service account must have READ access to that folder.
=============================================================================
*/

USE master;
GO

IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'HospitalAnalytics')
BEGIN
    ALTER DATABASE HospitalAnalytics SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE HospitalAnalytics;
END;
GO

CREATE DATABASE HospitalAnalytics;
GO

USE HospitalAnalytics;
GO

CREATE SCHEMA gold;
GO

/*
-----------------------------------------------------------------------------
 1. FINAL (TYPED) TABLES  -  the clean star schema
-----------------------------------------------------------------------------
   fact_visits (grain = one hospital visit) references seven dimensions:
   patients, providers, departments, diagnoses, procedures, insurance and
   (via patients) cities.
-----------------------------------------------------------------------------
*/

CREATE TABLE gold.dim_cities (
    city_id     INT           NOT NULL,
    city        NVARCHAR(50),
    region      NVARCHAR(50)          -- source column "State"
);
GO

CREATE TABLE gold.dim_departments (
    department_id  INT          NOT NULL,
    department     NVARCHAR(50)
);
GO

CREATE TABLE gold.dim_diagnoses (
    diagnosis_id   INT          NOT NULL,
    diagnosis      NVARCHAR(50)
);
GO

CREATE TABLE gold.dim_procedures (
    procedure_id   INT          NOT NULL,
    procedure_name NVARCHAR(50)       -- "procedure" is a reserved word
);
GO

CREATE TABLE gold.dim_insurance (
    insurance_id       INT          NOT NULL,
    insurance_provider NVARCHAR(50)
);
GO

CREATE TABLE gold.dim_providers (
    provider_id   INT           NOT NULL,
    provider_name NVARCHAR(100),
    gender        NVARCHAR(10),
    nationality   NVARCHAR(50),
    age           INT,
    image_url     NVARCHAR(255)
);
GO

CREATE TABLE gold.dim_patients (
    patient_id    INT           NOT NULL,
    patient_name  NVARCHAR(100),
    gender        NVARCHAR(10),
    age           INT,
    city_id       INT,
    race          NVARCHAR(50)
);
GO

CREATE TABLE gold.fact_visits (
    visit_id           INT IDENTITY(1,1) NOT NULL,  -- surrogate key (no natural id in source)
    date_of_visit      DATE,
    patient_id         INT,
    provider_id        INT,
    department_id      INT,
    diagnosis_id       INT,
    procedure_id       INT,
    insurance_id       INT,
    service_type       NVARCHAR(20),                -- Outpatient / Inpatient / Emergency
    treatment_cost     INT,
    medication_cost    INT,
    follow_up_date     DATE          NULL,
    satisfaction_score TINYINT,                     -- 1..10
    referral_source    NVARCHAR(30),
    emergency_visit    NVARCHAR(3),                 -- Yes / No
    payment_status     NVARCHAR(20),                -- Paid / Pending
    admitted_date      DATE          NULL,          -- inpatients only
    discharge_date     DATE          NULL,          -- inpatients only
    room_type          NVARCHAR(30)  NULL,          -- NULL for non-admitted
    insurance_coverage DECIMAL(10,2) NULL,
    room_daily_charge  INT
);
GO

/*
-----------------------------------------------------------------------------
 2. STAGING TABLES  -  everything as NVARCHAR so nothing rejects on load
-----------------------------------------------------------------------------
*/
CREATE TABLE gold.stg_cities       (city_id NVARCHAR(50), city NVARCHAR(50), region NVARCHAR(50));
CREATE TABLE gold.stg_departments  (department_id NVARCHAR(50), department NVARCHAR(50));
CREATE TABLE gold.stg_diagnoses    (diagnosis_id NVARCHAR(50), diagnosis NVARCHAR(50));
CREATE TABLE gold.stg_procedures   (procedure_id NVARCHAR(50), procedure_name NVARCHAR(50));
CREATE TABLE gold.stg_insurance    (insurance_id NVARCHAR(50), insurance_provider NVARCHAR(50));
CREATE TABLE gold.stg_providers    (provider_id NVARCHAR(50), provider_name NVARCHAR(100), gender NVARCHAR(10), nationality NVARCHAR(50), age NVARCHAR(50), image_url NVARCHAR(255));
CREATE TABLE gold.stg_patients     (patient_id NVARCHAR(50), patient_name NVARCHAR(100), gender NVARCHAR(10), age NVARCHAR(50), city_id NVARCHAR(50), race NVARCHAR(50));
CREATE TABLE gold.stg_visits (
    date_of_visit NVARCHAR(50), patient_id NVARCHAR(50), provider_id NVARCHAR(50),
    department_id NVARCHAR(50), diagnosis_id NVARCHAR(50), procedure_id NVARCHAR(50),
    insurance_id NVARCHAR(50), service_type NVARCHAR(50), treatment_cost NVARCHAR(50),
    medication_cost NVARCHAR(50), follow_up_date NVARCHAR(50), satisfaction_score NVARCHAR(50),
    referral_source NVARCHAR(50), emergency_visit NVARCHAR(50), payment_status NVARCHAR(50),
    discharge_date NVARCHAR(50), admitted_date NVARCHAR(50), room_type NVARCHAR(50),
    insurance_coverage NVARCHAR(50), room_daily_charge NVARCHAR(50)
);
GO

/*
-----------------------------------------------------------------------------
 3. BULK LOAD raw CSVs into staging
-----------------------------------------------------------------------------
   NOTE: BULK INSERT needs a literal path, so dynamic SQL injects a single
   @data_path. The source files have MIXED line endings (some \n, some \r\n)
   and NO quoted fields, so we deliberately AVOID FORMAT='CSV' (it throws
   "Msg 7301 ... provider BULK" on some setups) and instead split rows on \n
   (0x0a). On \r\n files this leaves a trailing carriage return on each row's
   LAST field only; that stray CHAR(13) is stripped in the cleaning step (4).
-----------------------------------------------------------------------------
*/
DECLARE @data_path NVARCHAR(260) = N'D:\JOB Search India\cv variations\NHS_Hospital_SQL_Project\datasets';   -- <<< EDIT THIS (trailing backslash optional)
IF RIGHT(@data_path, 1) <> '\' SET @data_path = @data_path + '\';   -- ensure the separator so path + filename is valid
DECLARE @sql NVARCHAR(MAX);

DECLARE @loads TABLE (tbl SYSNAME, fname NVARCHAR(100));
INSERT INTO @loads VALUES
 ('gold.stg_cities','cities.csv'),
 ('gold.stg_departments','departments.csv'),
 ('gold.stg_diagnoses','diagnoses.csv'),
 ('gold.stg_procedures','procedures.csv'),
 ('gold.stg_insurance','insurance.csv'),
 ('gold.stg_providers','providers.csv'),
 ('gold.stg_patients','patients.csv'),
 ('gold.stg_visits','visits.csv');

DECLARE @t SYSNAME, @f NVARCHAR(100);
DECLARE cur CURSOR FOR SELECT tbl, fname FROM @loads;
OPEN cur;
FETCH NEXT FROM cur INTO @t, @f;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'BULK INSERT ' + @t + N'
        FROM ''' + @data_path + @f + N'''
        WITH (FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', TABLOCK);';
    EXEC sp_executesql @sql;
    FETCH NEXT FROM cur INTO @t, @f;
END;
CLOSE cur; DEALLOCATE cur;
GO

/*
-----------------------------------------------------------------------------
 4. CLEAN + LOAD staging -> typed tables
-----------------------------------------------------------------------------
   Cleaning rules applied here:
     - NULLIF(col,'')                  : empty strings -> NULL
     - NULLIF(NULLIF(room_type,''),'N/A'): literal 'N/A' text -> NULL
     - TRY_CONVERT(DATE, col, 101)     : parse US m/d/yyyy safely
     - TRY_CONVERT(INT/DECIMAL, ...)   : bad numbers -> NULL instead of error
     - REPLACE(col, CHAR(13), '')      : strip trailing CR left on the LAST
                                         column of \r\n rows (see load note)
-----------------------------------------------------------------------------
*/
INSERT INTO gold.dim_cities (city_id, city, region)
SELECT TRY_CONVERT(INT, city_id), city, REPLACE(region, CHAR(13), '') FROM gold.stg_cities;

INSERT INTO gold.dim_departments (department_id, department)
SELECT TRY_CONVERT(INT, department_id), REPLACE(department, CHAR(13), '') FROM gold.stg_departments;

INSERT INTO gold.dim_diagnoses (diagnosis_id, diagnosis)
SELECT TRY_CONVERT(INT, diagnosis_id), REPLACE(diagnosis, CHAR(13), '') FROM gold.stg_diagnoses;

INSERT INTO gold.dim_procedures (procedure_id, procedure_name)
SELECT TRY_CONVERT(INT, procedure_id), REPLACE(procedure_name, CHAR(13), '') FROM gold.stg_procedures;

INSERT INTO gold.dim_insurance (insurance_id, insurance_provider)
SELECT TRY_CONVERT(INT, insurance_id), REPLACE(insurance_provider, CHAR(13), '') FROM gold.stg_insurance;

INSERT INTO gold.dim_providers (provider_id, provider_name, gender, nationality, age, image_url)
SELECT TRY_CONVERT(INT, provider_id), provider_name, gender, nationality,
       TRY_CONVERT(INT, age), REPLACE(image_url, CHAR(13), '')
FROM gold.stg_providers;

INSERT INTO gold.dim_patients (patient_id, patient_name, gender, age, city_id, race)
SELECT TRY_CONVERT(INT, patient_id), patient_name, gender,
       TRY_CONVERT(INT, age), TRY_CONVERT(INT, city_id), REPLACE(race, CHAR(13), '')
FROM gold.stg_patients;

INSERT INTO gold.fact_visits
    (date_of_visit, patient_id, provider_id, department_id, diagnosis_id, procedure_id,
     insurance_id, service_type, treatment_cost, medication_cost, follow_up_date,
     satisfaction_score, referral_source, emergency_visit, payment_status,
     admitted_date, discharge_date, room_type, insurance_coverage, room_daily_charge)
SELECT
     TRY_CONVERT(DATE, NULLIF(date_of_visit,''), 101),
     TRY_CONVERT(INT, patient_id),
     TRY_CONVERT(INT, provider_id),
     TRY_CONVERT(INT, department_id),
     TRY_CONVERT(INT, diagnosis_id),
     TRY_CONVERT(INT, procedure_id),
     TRY_CONVERT(INT, insurance_id),
     service_type,
     TRY_CONVERT(INT, treatment_cost),
     TRY_CONVERT(INT, medication_cost),
     TRY_CONVERT(DATE, NULLIF(follow_up_date,''), 101),
     TRY_CONVERT(TINYINT, satisfaction_score),
     referral_source,
     emergency_visit,
     payment_status,
     TRY_CONVERT(DATE, NULLIF(admitted_date,''), 101),
     TRY_CONVERT(DATE, NULLIF(discharge_date,''), 101),
     NULLIF(NULLIF(room_type,''),'N/A'),
     TRY_CONVERT(DECIMAL(10,2), NULLIF(insurance_coverage,'')),
     TRY_CONVERT(INT, REPLACE(room_daily_charge, CHAR(13), ''))   -- last column: strip trailing CR
FROM gold.stg_visits;
GO

/*
-----------------------------------------------------------------------------
 5. KEYS  (added after load; source data is already referentially clean)
-----------------------------------------------------------------------------
*/
ALTER TABLE gold.dim_cities      ADD CONSTRAINT PK_dim_cities      PRIMARY KEY (city_id);
ALTER TABLE gold.dim_departments ADD CONSTRAINT PK_dim_departments PRIMARY KEY (department_id);
ALTER TABLE gold.dim_diagnoses   ADD CONSTRAINT PK_dim_diagnoses   PRIMARY KEY (diagnosis_id);
ALTER TABLE gold.dim_procedures  ADD CONSTRAINT PK_dim_procedures  PRIMARY KEY (procedure_id);
ALTER TABLE gold.dim_insurance   ADD CONSTRAINT PK_dim_insurance   PRIMARY KEY (insurance_id);
ALTER TABLE gold.dim_providers   ADD CONSTRAINT PK_dim_providers   PRIMARY KEY (provider_id);
ALTER TABLE gold.dim_patients    ADD CONSTRAINT PK_dim_patients    PRIMARY KEY (patient_id);
ALTER TABLE gold.fact_visits     ADD CONSTRAINT PK_fact_visits     PRIMARY KEY (visit_id);
GO

/*
-----------------------------------------------------------------------------
 6. DROP staging (optional housekeeping)
-----------------------------------------------------------------------------
*/
DROP TABLE gold.stg_cities, gold.stg_departments, gold.stg_diagnoses,
           gold.stg_procedures, gold.stg_insurance, gold.stg_providers,
           gold.stg_patients, gold.stg_visits;
GO

-- Quick load check
SELECT 'dim_patients' AS tbl, COUNT(*) AS rows FROM gold.dim_patients
UNION ALL SELECT 'dim_providers',  COUNT(*) FROM gold.dim_providers
UNION ALL SELECT 'dim_cities',     COUNT(*) FROM gold.dim_cities
UNION ALL SELECT 'fact_visits',    COUNT(*) FROM gold.fact_visits;
GO
