-- AA interception range as real unit data (Gathering Storm type names).
-- SQL UPDATE instead of XML Row: Row uses REPLACE semantics and fails NOT NULL
-- columns (Units.Name) when only a subset of columns is given.
UPDATE Units SET Range=2 WHERE UnitType='UNIT_ANTIAIR_GUN';
UPDATE Units SET Range=3 WHERE UnitType='UNIT_MOBILE_SAM';
