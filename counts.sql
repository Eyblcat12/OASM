SELECT format('targets_in_project_workspace=%s', count(*))
FROM public.targets
WHERE "workspaceId" = :'project_workspace_id'::uuid;
SELECT format('targets_all=%s', count(*)) FROM public.targets;
SELECT format('workspaces=%s', count(*)) FROM public.workspaces;
SELECT format('users=%s', count(*)) FROM public.users;
SELECT format('projects=%s', count(*)) FROM public.projects;
SELECT format('assets=%s', count(*)) FROM public.assets;
SELECT format('services=%s', count(*)) FROM public.asset_services;
SELECT format('job_histories=%s', count(*)) FROM public.job_histories;
SELECT format('jobs=%s', count(*)) FROM public.jobs;
SELECT format('findings=%s', count(*)) FROM public.vulnerabilities;
