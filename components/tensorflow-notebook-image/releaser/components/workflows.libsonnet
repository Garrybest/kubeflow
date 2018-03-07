{
  // TODO(https://github.com/ksonnet/ksonnet/issues/222): Taking namespace as an argument is a work around for the fact that ksonnet
  // doesn't support automatically piping in the namespace from the environment to prototypes.

  // convert a list of two items into a map representing an environment variable
  listToMap:: function(v)
    {
      name: v[0],
      value: v[1],
    },

  // Function to turn comma separated list of prow environment variables into a dictionary.
  parseEnv:: function(v)
    local pieces = std.split(v, ",");
    if v != "" && std.length(pieces) > 0 then
      std.map(
        function(i) $.listToMap(std.split(i, "=")),
        std.split(v, ",")
      )
    else [],


  // Default parameters.
  // The defaults are suitable based on suitable values for our test cluster.
  defaultParams:: {
      bucket: "kubeflow-ci_temp",
      commit: "master",
      // Name of the secret containing GCP credentials.
      gcpCredentialsSecretName: "kubeflow-testing-credentials",
      name: "kubeflow-postsubmit",
      namespace: "kubeflow-test-infra",
       // The name of the NFS volume claim to use for test files.
      nfsVolumeClaim: "nfs-external",
      prow_env: "REPO_OWNER=kubeflow,REPO_NAME=kubeflow,PULL_BASE_SHA=master",      
      // The default image to use for the steps in the Argo workflow.      
      step_image: "gcr.io/kubeflow-ci/test-worker:latest",

      // The registry to use (should not include the image name or version tag)
      registry: "gcr.io/kubeflow-ci",

      // The tag to use for the image.
      versionTag: "latest",
  },

  parts(namespace, name, overrides={}):: {
    // Workflow to run the e2e test.
    e2e::
      local params = $.defaultParams + overrides;

      local namespace = params.namespace;      
      local name = params.name;

      local prow_env = $.parseEnv(params.prow_env);
      local bucket = params.bucket;

      local stepsNamespace = name;
    
      local cpuImage = params.registry +  "/tensorflow-notebook-cpu" + ":" + params.versionTag;
      local gpuImage = params.registry +  "/tensorflow-notebook-gpu" + ":" + params.versionTag;
      // mountPath is the directory where the volume to store the test data
      // should be mounted.
      local mountPath = "/mnt/" + "test-data-volume";
      // testDir is the root directory for all data for a particular test run.
      local testDir = mountPath + "/" + name;
      // outputDir is the directory to sync to GCS to contain the output for this job.
      local outputDir = testDir + "/output";
      local artifactsDir = outputDir + "/artifacts";
      // Source directory where all repos should be checked out
      local srcRootDir = testDir + "/src";
      // The directory containing the kubeflow/kubeflow repo
      local srcDir = srcRootDir + "/kubeflow/kubeflow";
      // The name to use for the volume to use to contain test data.
      local dataVolume = "kubeflow-test-volume";
      local kubeflowPy = srcDir;
      // The directory within the kubeflow_testing submodule containing
      // py scripts to use.
      local kubeflowTestingPy = srcRootDir + "/kubeflow/testing/py";

      // Location where Dockerfiles and other sources are found.
      local notebookDir = srcRootDir + "/kubeflow/kubeflow/components/tensorflow-notebook-image/";

      // Build an Argo template to execute a particular command.
      // step_name: Name for the template
      // command: List to pass as the container command.
      local buildTemplate(step_name, command, env_vars=[], sidecars=[])= {
          name: step_name,
          container: {
            command: command,
            image: params.step_image,
            env: [
              {
                // Add the source directories to the python path.
                name: "PYTHONPATH",
                value: kubeflowPy + ":" + kubeflowTestingPy,
              },
              {
                name: "GOOGLE_APPLICATION_CREDENTIALS",
                value: "/secret/gcp-credentials/key.json",
              },
              {
                name: "GITHUB_TOKEN",
                valueFrom: {
                  secretKeyRef: {
                    name: "github-token",
                    key: "github_token",
                  },
                },
              },
            ] + prow_env + env_vars,
            volumeMounts: [
              {
                name: dataVolume,
                mountPath: mountPath,
              },
              {
                name: "github-token",
                mountPath: "/secret/github-token",
              },
              {
                name: "gcp-credentials",
                mountPath: "/secret/gcp-credentials",
              },
            ],
          },
          sidecars: sidecars,
        };  // buildTemplate

      local buildImageTemplate(step_name, image, base_image, tf_package) = 
      buildTemplate(
              step_name,
              [
                // We need to explicitly specify bash because
                // build_image.sh is not in the container its a volume mounted file.
                "/bin/bash", "-c",                
                notebookDir + "build_image.sh "
                + notebookDir +  "Dockerfile" + " "
                + image + " "
                + base_image + " "
                + tf_package,
              ],
              [
                {
                  name: "DOCKER_HOST",
                  value: "127.0.0.1",
                },
              ],
              [{
                name: "dind",
                image: "docker:17.10-dind",
                securityContext: {
                  privileged: true,
                },
                mirrorVolumeMounts: true,
              }],
            ); // buildImageTemplate
      {       
        apiVersion: "argoproj.io/v1alpha1",
        kind: "Workflow",
        metadata: {
          name: name,
          namespace: namespace,
        },
        // TODO(jlewi): Use OnExit to run cleanup steps.
        spec: {
          entrypoint: "e2e",
          volumes: [
            {
              name: "github-token",
              secret: {
                secretName: "github-token",
              },
            },
            {
              name: "gcp-credentials",
              secret: {
                secretName: params.gcpCredentialsSecretName,
              },
            },
            {
              name: dataVolume,
              persistentVolumeClaim: {
                claimName: params.nfsVolumeClaim,
              },
            },
          ],  // volumes

          // onExit specifies the template that should always run when the workflow completes.
          onExit: "exit-handler",

          templates: [
            {
              name: "e2e",
              dag: {
                tasks: [
                  {name: "checkout",
                   template: "checkout",                
                  },
                  { 
                  name: "build-cpu-notebook",
                  template: "build-cpu-notebook",
                  dependencies: ["checkout"],
                  },
                  { 
                  name: "build-gpu-notebook",
                  template: "build-gpu-notebook",
                  dependencies: ["checkout"],
                  },
                  {name: "create-pr-symlink",
                   template: "create-pr-symlink",
                   dependencies: ["checkout"],
                  },
                ]
              }, //dag 
            },
            {
              name: "exit-handler",              
              steps: [
                [{
                  name: "copy-artifacts",
                  template: "copy-artifacts",
                }],
              ],
            },
            {
              name: "checkout",
              container: {
                command: [
                  "/usr/local/bin/checkout.sh",
                ],
                args: [
                  srcRootDir,
                ],
                env: prow_env + [{
                  name: "EXTRA_REPOS",
                  value: "kubeflow/testing@HEAD",
                }],
                image: params.step_image,
                volumeMounts: [
                  {
                    name: dataVolume,
                    mountPath: mountPath,
                  },
                ],
              },
            },  // checkout            
            buildImageTemplate("build-cpu-notebook", cpuImage, "ubuntu:latest", "tf-nightly"),
            buildImageTemplate("build-gpu-notebook", gpuImage, "nvidia/cuda:8.0-cudnn6-devel-ubuntu16.04", "tf-nightly-gpu"),
            buildTemplate("create-pr-symlink", [
              "python",
              "-m",
              "kubeflow.testing.prow_artifacts",
              "--artifacts_dir=" + outputDir,
              "create_pr_symlink",
              "--bucket=" + bucket,
            ]),  // create-pr-symlink
            buildTemplate(
              "copy-artifacts",
              [
                "python",
                "-m",
                "kubeflow.testing.prow_artifacts",
                "--artifacts_dir=" + outputDir,
                "copy_artifacts",
                "--bucket=" + bucket,
              ]
            ),  // copy-artifacts
          ],  // templates
        },
      },  // e2e
  },  // parts
}