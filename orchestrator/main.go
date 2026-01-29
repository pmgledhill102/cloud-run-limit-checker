package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	run "cloud.google.com/go/run/apiv2"
	"cloud.google.com/go/run/apiv2/runpb"

	"cloud.google.com/go/logging"
	"cloud.google.com/go/logging/logadmin"
	"google.golang.org/api/iterator"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/durationpb"
)

type config struct {
	Project      string
	Region       string
	Network      string
	Subnet       string
	TargetURL    string
	ServiceImage string
	CheckerImage string
	Count        int
	Prefix       string
	Cleanup      bool
	VerifyOnly   bool
}

func main() {
	cfg := config{}

	flag.StringVar(&cfg.Project, "project", "", "GCP project ID (required)")
	flag.StringVar(&cfg.Region, "region", "", "GCP region (required)")
	flag.StringVar(&cfg.Network, "network", "", "VPC network name (required)")
	flag.StringVar(&cfg.Subnet, "subnet", "", "Subnet name (required)")
	flag.StringVar(&cfg.TargetURL, "target-url", "", "Internal IP + port of target service (required)")
	flag.StringVar(&cfg.ServiceImage, "service-image", "", "Container image URI for service (required)")
	flag.StringVar(&cfg.CheckerImage, "checker-image", "", "Container image URI for checker job (required)")
	flag.IntVar(&cfg.Count, "count", 10, "Number of services to deploy")
	flag.StringVar(&cfg.Prefix, "prefix", "service", "Service name prefix")
	flag.BoolVar(&cfg.Cleanup, "cleanup", false, "Delete all services and checker job")
	flag.BoolVar(&cfg.VerifyOnly, "verify-only", false, "Skip deployment, only run checker")
	flag.Parse()

	// Validate required flags
	missing := []string{}
	if cfg.Project == "" {
		missing = append(missing, "--project")
	}
	if cfg.Region == "" {
		missing = append(missing, "--region")
	}
	if cfg.Network == "" {
		missing = append(missing, "--network")
	}
	if cfg.Subnet == "" {
		missing = append(missing, "--subnet")
	}
	if cfg.TargetURL == "" {
		missing = append(missing, "--target-url")
	}
	if !cfg.Cleanup && !cfg.VerifyOnly && cfg.ServiceImage == "" {
		missing = append(missing, "--service-image")
	}
	if !cfg.Cleanup && cfg.CheckerImage == "" {
		missing = append(missing, "--checker-image")
	}
	if len(missing) > 0 {
		logJSON("ERROR", map[string]string{
			"event":   "missing_flags",
			"message": fmt.Sprintf("missing required flags: %s", strings.Join(missing, ", ")),
		})
		os.Exit(1)
	}

	ctx := context.Background()
	var err error

	switch {
	case cfg.Cleanup:
		err = runCleanup(ctx, cfg)
	case cfg.VerifyOnly:
		err = runVerifyOnly(ctx, cfg)
	default:
		err = runDeployAndVerify(ctx, cfg)
	}

	if err != nil {
		logJSON("ERROR", map[string]string{
			"event": "fatal",
			"error": err.Error(),
		})
		os.Exit(1)
	}
}

func runDeployAndVerify(ctx context.Context, cfg config) error {
	if err := deployServices(ctx, cfg); err != nil {
		return fmt.Errorf("deploying services: %w", err)
	}
	if err := runChecker(ctx, cfg); err != nil {
		return fmt.Errorf("running checker: %w", err)
	}
	return nil
}

func runVerifyOnly(ctx context.Context, cfg config) error {
	if err := runChecker(ctx, cfg); err != nil {
		return fmt.Errorf("running checker: %w", err)
	}
	return nil
}

func runCleanup(ctx context.Context, cfg config) error {
	if err := deleteServices(ctx, cfg); err != nil {
		return fmt.Errorf("deleting services: %w", err)
	}
	if err := deleteCheckerJob(ctx, cfg); err != nil {
		return fmt.Errorf("deleting checker job: %w", err)
	}
	return nil
}

func deployServices(ctx context.Context, cfg config) error {
	client, err := run.NewServicesClient(ctx)
	if err != nil {
		return fmt.Errorf("creating services client: %w", err)
	}
	defer client.Close()

	parent := fmt.Sprintf("projects/%s/locations/%s", cfg.Project, cfg.Region)

	logJSON("INFO", map[string]string{
		"event": "deploy_start",
		"count": strconv.Itoa(cfg.Count),
	})

	// Fire loop: create all services
	type opEntry struct {
		name string
		op   *run.CreateServiceOperation
	}
	var ops []opEntry
	skipped := 0

	for i := 0; i < cfg.Count; i++ {
		name := serviceName(cfg.Prefix, i)
		svc := buildServiceSpec(cfg, name)

		op, err := client.CreateService(ctx, &runpb.CreateServiceRequest{
			Parent:    parent,
			ServiceId: name,
			Service:   svc,
		})
		if err != nil {
			if isAlreadyExists(err) {
				logJSON("INFO", map[string]string{
					"event":   "service_already_exists",
					"service": name,
				})
				skipped++
				continue
			}
			logJSON("ERROR", map[string]string{
				"event":   "create_service_failed",
				"service": name,
				"error":   err.Error(),
			})
			continue
		}
		ops = append(ops, opEntry{name: name, op: op})
	}

	// Wait loop: wait for all operations to complete
	succeeded := skipped
	failed := 0
	for _, entry := range ops {
		_, err := entry.op.Wait(ctx)
		if err != nil {
			logJSON("ERROR", map[string]string{
				"event":   "service_deploy_failed",
				"service": entry.name,
				"error":   err.Error(),
			})
			failed++
			continue
		}
		logJSON("INFO", map[string]string{
			"event":   "service_deployed",
			"service": entry.name,
		})
		succeeded++
	}

	logJSON("INFO", map[string]string{
		"event":     "deploy_summary",
		"succeeded": strconv.Itoa(succeeded),
		"failed":    strconv.Itoa(failed),
		"skipped":   strconv.Itoa(skipped),
		"total":     strconv.Itoa(cfg.Count),
	})

	if failed > 0 {
		return fmt.Errorf("%d service(s) failed to deploy", failed)
	}
	return nil
}

func buildServiceSpec(cfg config, name string) *runpb.Service {
	return &runpb.Service{
		Ingress: runpb.IngressTraffic_INGRESS_TRAFFIC_INTERNAL_ONLY,
		Template: &runpb.RevisionTemplate{
			VpcAccess: &runpb.VpcAccess{
				Egress: runpb.VpcAccess_ALL_TRAFFIC,
				NetworkInterfaces: []*runpb.VpcAccess_NetworkInterface{
					{
						Network:    cfg.Network,
						Subnetwork: cfg.Subnet,
					},
				},
			},
			Scaling: &runpb.RevisionScaling{
				MinInstanceCount: 1,
				MaxInstanceCount: 1,
			},
			Containers: []*runpb.Container{
				{
					Image: cfg.ServiceImage,
					Ports: []*runpb.ContainerPort{
						{ContainerPort: 8080},
					},
					Resources: &runpb.ResourceRequirements{
						Limits: map[string]string{
							"cpu":    "0.08",
							"memory": "128Mi",
						},
					},
					Env: []*runpb.EnvVar{
						{Name: "TARGET_URL", Values: &runpb.EnvVar_Value{Value: cfg.TargetURL}},
						{Name: "SERVICE_NAME", Values: &runpb.EnvVar_Value{Value: name}},
					},
				},
			},
		},
	}
}

func deleteServices(ctx context.Context, cfg config) error {
	client, err := run.NewServicesClient(ctx)
	if err != nil {
		return fmt.Errorf("creating services client: %w", err)
	}
	defer client.Close()

	parent := fmt.Sprintf("projects/%s/locations/%s", cfg.Project, cfg.Region)

	// List services matching prefix
	var serviceNames []string
	it := client.ListServices(ctx, &runpb.ListServicesRequest{Parent: parent})
	for {
		svc, err := it.Next()
		if err == iterator.Done {
			break
		}
		if err != nil {
			return fmt.Errorf("listing services: %w", err)
		}
		parts := strings.Split(svc.Name, "/")
		shortName := parts[len(parts)-1]
		if strings.HasPrefix(shortName, cfg.Prefix+"-") {
			serviceNames = append(serviceNames, svc.Name)
		}
	}

	logJSON("INFO", map[string]string{
		"event": "delete_start",
		"count": strconv.Itoa(len(serviceNames)),
	})

	// Fire loop: delete all services
	type opEntry struct {
		name string
		op   *run.DeleteServiceOperation
	}
	var ops []opEntry

	for _, fullName := range serviceNames {
		op, err := client.DeleteService(ctx, &runpb.DeleteServiceRequest{Name: fullName})
		if err != nil {
			if isNotFound(err) {
				logJSON("INFO", map[string]string{
					"event":   "service_not_found",
					"service": fullName,
				})
				continue
			}
			logJSON("ERROR", map[string]string{
				"event":   "delete_service_failed",
				"service": fullName,
				"error":   err.Error(),
			})
			continue
		}
		ops = append(ops, opEntry{name: fullName, op: op})
	}

	// Wait loop: wait for all operations to complete
	succeeded := 0
	failed := 0
	for _, entry := range ops {
		_, err := entry.op.Wait(ctx)
		if err != nil {
			logJSON("ERROR", map[string]string{
				"event":   "service_delete_failed",
				"service": entry.name,
				"error":   err.Error(),
			})
			failed++
			continue
		}
		parts := strings.Split(entry.name, "/")
		shortName := parts[len(parts)-1]
		logJSON("INFO", map[string]string{
			"event":   "service_deleted",
			"service": shortName,
		})
		succeeded++
	}

	logJSON("INFO", map[string]string{
		"event":     "delete_summary",
		"succeeded": strconv.Itoa(succeeded),
		"failed":    strconv.Itoa(failed),
		"total":     strconv.Itoa(len(serviceNames)),
	})

	if failed > 0 {
		return fmt.Errorf("%d service(s) failed to delete", failed)
	}
	return nil
}

func serviceName(prefix string, index int) string {
	return fmt.Sprintf("%s-%03d", prefix, index)
}

func runChecker(ctx context.Context, cfg config) error {
	client, err := run.NewJobsClient(ctx)
	if err != nil {
		return fmt.Errorf("creating jobs client: %w", err)
	}
	defer client.Close()

	parent := fmt.Sprintf("projects/%s/locations/%s", cfg.Project, cfg.Region)
	jobName := fmt.Sprintf("%s/jobs/checker", parent)

	if err := ensureCheckerJob(ctx, client, cfg, parent, jobName); err != nil {
		return fmt.Errorf("ensuring checker job: %w", err)
	}

	// Run the job
	logJSON("INFO", map[string]string{
		"event": "checker_run_start",
		"job":   jobName,
	})

	runOp, err := client.RunJob(ctx, &runpb.RunJobRequest{Name: jobName})
	if err != nil {
		return fmt.Errorf("running checker job: %w", err)
	}

	// Wait for the execution to complete
	execution, err := runOp.Wait(ctx)
	if err != nil {
		return fmt.Errorf("waiting for checker job: %w", err)
	}

	executionName := execution.Name

	logJSON("INFO", map[string]string{
		"event":          "checker_run_complete",
		"execution":      executionName,
		"succeeded_count": strconv.Itoa(int(execution.SucceededCount)),
		"failed_count":   strconv.Itoa(int(execution.FailedCount)),
	})

	// Read logs from the execution
	if err := readCheckerLogs(ctx, cfg, jobName, executionName); err != nil {
		logJSON("WARN", map[string]string{
			"event": "log_read_failed",
			"error": err.Error(),
		})
	}

	if execution.FailedCount > 0 {
		return fmt.Errorf("checker job failed: %d task(s) failed", execution.FailedCount)
	}
	return nil
}

func ensureCheckerJob(ctx context.Context, client *run.JobsClient, cfg config, parent, jobName string) error {
	job := buildJobSpec(cfg)

	_, err := client.CreateJob(ctx, &runpb.CreateJobRequest{
		Parent: parent,
		JobId:  "checker",
		Job:    job,
	})
	if err != nil {
		if isAlreadyExists(err) {
			logJSON("INFO", map[string]string{
				"event": "checker_job_exists",
				"job":   jobName,
			})
			// Update existing job
			job.Name = jobName
			_, err := client.UpdateJob(ctx, &runpb.UpdateJobRequest{
				Job: job,
			})
			if err != nil {
				return fmt.Errorf("updating checker job: %w", err)
			}
			logJSON("INFO", map[string]string{
				"event": "checker_job_updated",
				"job":   jobName,
			})
			return nil
		}
		return fmt.Errorf("creating checker job: %w", err)
	}

	logJSON("INFO", map[string]string{
		"event": "checker_job_created",
		"job":   jobName,
	})
	return nil
}

func buildJobSpec(cfg config) *runpb.Job {
	return &runpb.Job{
		Template: &runpb.ExecutionTemplate{
			TaskCount:   1,
			Parallelism: 1,
			Template: &runpb.TaskTemplate{
				Retries: &runpb.TaskTemplate_MaxRetries{MaxRetries: 0},
				Timeout: durationpb.New(30 * time.Minute),
				Containers: []*runpb.Container{
					{
						Image: cfg.CheckerImage,
						Resources: &runpb.ResourceRequirements{
							Limits: map[string]string{
								"cpu":    "1",
								"memory": "512Mi",
							},
						},
						Env: []*runpb.EnvVar{
							{Name: "PROJECT_ID", Values: &runpb.EnvVar_Value{Value: cfg.Project}},
							{Name: "REGION", Values: &runpb.EnvVar_Value{Value: cfg.Region}},
							{Name: "PREFIX", Values: &runpb.EnvVar_Value{Value: cfg.Prefix}},
							{Name: "CONCURRENCY", Values: &runpb.EnvVar_Value{Value: "10"}},
						},
					},
				},
				VpcAccess: &runpb.VpcAccess{
					Egress: runpb.VpcAccess_ALL_TRAFFIC,
					NetworkInterfaces: []*runpb.VpcAccess_NetworkInterface{
						{
							Network:    cfg.Network,
							Subnetwork: cfg.Subnet,
						},
					},
				},
			},
		},
	}
}

func deleteCheckerJob(ctx context.Context, cfg config) error {
	client, err := run.NewJobsClient(ctx)
	if err != nil {
		return fmt.Errorf("creating jobs client: %w", err)
	}
	defer client.Close()

	jobName := fmt.Sprintf("projects/%s/locations/%s/jobs/checker", cfg.Project, cfg.Region)

	logJSON("INFO", map[string]string{
		"event": "delete_checker_job",
		"job":   jobName,
	})

	_, err = client.DeleteJob(ctx, &runpb.DeleteJobRequest{Name: jobName})
	if err != nil {
		if isNotFound(err) {
			logJSON("INFO", map[string]string{
				"event": "checker_job_not_found",
				"job":   jobName,
			})
			return nil
		}
		return fmt.Errorf("deleting checker job: %w", err)
	}

	logJSON("INFO", map[string]string{
		"event": "checker_job_deleted",
		"job":   jobName,
	})
	return nil
}

func readCheckerLogs(ctx context.Context, cfg config, jobName, executionName string) error {
	// Wait for log ingestion delay
	logJSON("INFO", map[string]string{
		"event":   "waiting_for_logs",
		"message": "sleeping 10s for log ingestion",
	})
	time.Sleep(10 * time.Second)

	adminClient, err := logadmin.NewClient(ctx, cfg.Project)
	if err != nil {
		return fmt.Errorf("creating logadmin client: %w", err)
	}
	defer adminClient.Close()

	// Extract execution short name from full resource name
	// Format: projects/{project}/locations/{location}/jobs/{job}/executions/{execution}
	parts := strings.Split(executionName, "/")
	executionShort := parts[len(parts)-1]

	filter := fmt.Sprintf(
		`resource.type="cloud_run_job" AND resource.labels.job_name="checker" AND labels."run.googleapis.com/execution_name"="%s"`,
		executionShort,
	)

	logJSON("INFO", map[string]string{
		"event":  "reading_logs",
		"filter": filter,
	})

	it := adminClient.Entries(ctx, logadmin.Filter(filter))
	count := 0
	for {
		entry, err := it.Next()
		if err == iterator.Done {
			break
		}
		if err != nil {
			return fmt.Errorf("reading log entries: %w", err)
		}
		printLogEntry(entry)
		count++
	}

	logJSON("INFO", map[string]string{
		"event": "logs_read",
		"count": strconv.Itoa(count),
	})
	return nil
}

func printLogEntry(entry *logging.Entry) {
	switch payload := entry.Payload.(type) {
	case string:
		fmt.Println(payload)
	default:
		data, err := json.Marshal(payload)
		if err != nil {
			fmt.Printf("%v\n", payload)
			return
		}
		fmt.Println(string(data))
	}
}

func logJSON(severity string, fields map[string]string) {
	entry := make(map[string]string, len(fields)+2)
	entry["severity"] = severity
	entry["time"] = time.Now().UTC().Format(time.RFC3339)
	for k, v := range fields {
		entry[k] = v
	}
	data, _ := json.Marshal(entry)
	fmt.Println(string(data))
}

func isAlreadyExists(err error) bool {
	st, ok := status.FromError(err)
	return ok && st.Code() == codes.AlreadyExists
}

func isNotFound(err error) bool {
	st, ok := status.FromError(err)
	return ok && st.Code() == codes.NotFound
}
