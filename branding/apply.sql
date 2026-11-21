BEGIN;
LOCK TABLE public.system_configs IN SHARE ROW EXCLUSIVE MODE;

-- A null logoPath tells the console to use its packaged /logo.png.
UPDATE public.system_configs
SET name = 'NCS OASM', "logoPath" = NULL, "updatedAt" = now()
WHERE name IS DISTINCT FROM 'NCS OASM' OR "logoPath" IS NOT NULL;

INSERT INTO public.system_configs (name)
SELECT 'NCS OASM'
WHERE NOT EXISTS (SELECT 1 FROM public.system_configs);
COMMIT;
