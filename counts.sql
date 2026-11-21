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
\if :{?include_configuration_counts}
SELECT format('project_workflows=%s', count(*)) FROM public.project_workflows;
SELECT format('project_workflow_triggers=%s', count(*)) FROM public.project_workflow_triggers;
SELECT format('project_scope_rules=%s', count(*)) FROM public.project_scope_rules;
SELECT format('tool_config_profiles=%s', count(*)) FROM public.tool_config_profiles;
SELECT format('workspace_tools=%s', count(*)) FROM public.workspace_tools;
SELECT format('integrations=%s', count(*)) FROM public.integrations;
\endif
