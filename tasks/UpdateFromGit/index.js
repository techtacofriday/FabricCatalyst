"use strict";

const tl   = require('azure-pipelines-task-lib/task');
const path = require('path');
const { spawnSync } = require('child_process');

function run() {
    try {
        const env = Object.assign({}, process.env);

        // Service connection
        const connName = tl.getInput('azureSubscription', true);
        const ep       = tl.getEndpointAuthorization(connName, false);
        if (ep) {
            env.FC_AUTH_SCHEME = ep.scheme;
            env.FC_TENANT_ID   = ep.parameters['tenantid']           || '';
            env.FC_CLIENT_ID   = ep.parameters['serviceprincipalid']  || '';
            env.FC_CLIENT_KEY  = ep.parameters['serviceprincipalkey'] || '';
        }
        env.FC_SERVICE_CONNECTION_ID =
            tl.getEndpointDataParameter(connName, 'serviceConnectionId', true) || connName;

        // String inputs
        for (const name of [
            'workspaceName', 'fabricGitConnectionName', 'semanticModelsBinding', 'folderName',
        ]) {
            env[`FC_${name.toUpperCase()}`] = tl.getInput(name, false) || '';
        }

        // Boolean inputs (PowerShell expects 'True'/'False')
        for (const name of [
            'isWorkspaceGitEnabled', 'enableDiagnostics',
        ]) {
            env[`FC_${name.toUpperCase()}`] = tl.getBoolInput(name, false) ? 'True' : 'False';
        }

        // Invoke run.ps1
        const script = path.join(__dirname, 'run.ps1');
        const result = spawnSync(
            'pwsh',
            ['-NonInteractive', '-NoProfile', '-ExecutionPolicy', 'Unrestricted', '-File', script],
            { env, stdio: 'inherit' }
        );

        if (result.status !== 0) {
            tl.setResult(tl.TaskResult.Failed, `run.ps1 exited with code ${result.status}`);
        } else {
            tl.setResult(tl.TaskResult.Succeeded, 'Update from Git completed successfully.');
        }
    } catch (err) {
        tl.setResult(tl.TaskResult.Failed, err.message);
    }
}

run();
