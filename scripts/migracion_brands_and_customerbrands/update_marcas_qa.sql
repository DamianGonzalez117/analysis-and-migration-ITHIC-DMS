BEGIN;
INSERT INTO core.shared_customers (shared_customer_id, customer_id, subsidiary_id, reference_key, object_status_id, created_by, updated_by, created_at, updated_at, cat_customer_type_id, corporative, tax_id, external_id, is_cession_only) VALUES ('a9d20445-22ac-4066-8d89-7090716bc391', '01904ccf-6572-7750-80c8-5c55eb10d8bd', '019055d0-7a3c-7972-87f3-b52706b4fc67', NULL, '01905186-4fed-7080-aeee-9c71a939f69a', 'migracion@muhami.mx', NULL, '2026-10-19 23:03:06.652126+00', '2026-10-19 23:03:06.652128+00', '0190603b-315b-7b2c-a149-1460902f9f27', NULL, NULL, NULL, FALSE);
UPDATE core.sub_brands SET external_id = '68159', name = 'TENIS CHARLY', short_name = 'TENCHA', description = 'TENIS CHARLY', brand_id = '019cb537-c9e0-7220-966b-0b705c2c1db4', customer_brand_id = '01a1476a-64a9-720e-86d2-b078ca84e29a' WHERE sub_brand_id = '019e9059-6e39-741c-9387-4d7a4781780b' AND external_id = '45661';
UPDATE core.sub_brands SET customer_brand_id = '01a1476a-8d38-77ad-bd05-eb558672131c' WHERE sub_brand_id = '3fbcd0b3-7e3b-430a-e063-951b400aa6a8';
UPDATE core.sub_brands SET customer_brand_id = '01a1476a-e46d-7118-b32e-c27f121336f4' WHERE sub_brand_id = '1f362dc9-810f-7b09-e063-951b400aef46';
UPDATE core.sub_brands SET customer_brand_id = '01a1476b-0482-7129-ad4c-35a646c98d76' WHERE sub_brand_id = '1f362dc9-7442-7b09-e063-951b400aef46';
UPDATE core.sub_brands SET customer_brand_id = '01a1476b-3766-703e-bbff-01314a76b555' WHERE sub_brand_id = '1f362dc9-7d13-7b09-e063-951b400aef46';
UPDATE core.sub_brands SET customer_brand_id = '01a1476b-5f0f-757f-9bf6-37da5f6208d8' WHERE sub_brand_id = '1f362dc9-6a80-7b09-e063-951b400aef46';
COMMIT;
