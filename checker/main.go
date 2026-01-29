package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	run "cloud.google.com/go/run/apiv2"
	"cloud.google.com/go/run/apiv2/runpb"
	"google.golang.org/api/iterator"
)

type serviceInfo struct {
	Name string
	URI  string
}

type result struct {
	Service    string `json:"service"`
	URL        string `json:"url"`
	StatusCode int    `json:"status_code"`
	Body       string `json:"body"`
	Pass       bool   `json:"pass"`
	Error      string `json:"error,omitempty"`
}

func main() {
	projectID := requireEnv("PROJECT_ID")
	region := requireEnv("REGION")
	prefix := requireEnv("PREFIX")
	concurrency := parseConcurrency(os.Getenv("CONCURRENCY"), 10)

	logJSON("INFO", map[string]string{
		"event":       "startup",
		"project_id":  projectID,
		"region":      region,
		"prefix":      prefix,
		"concurrency": strconv.Itoa(concurrency),
	})

	ctx := context.Background()
	services, err := listServices(ctx, projectID, region, prefix)
	if err != nil {
		logJSON("ERROR", map[string]string{
			"event": "list_services_failed",
			"error": err.Error(),
		})
		os.Exit(1)
	}

	if len(services) == 0 {
		logJSON("ERROR", map[string]string{
			"event":   "no_services",
			"message": fmt.Sprintf("no services found with prefix %q", prefix),
		})
		os.Exit(1)
	}

	logJSON("INFO", map[string]string{
		"event": "services_found",
		"count": strconv.Itoa(len(services)),
	})

	results := pingAll(services, concurrency)

	passed := 0
	failed := 0
	for _, r := range results {
		fields := map[string]string{
			"event":       "ping_result",
			"service":     r.Service,
			"url":         r.URL,
			"status_code": strconv.Itoa(r.StatusCode),
			"body":        r.Body,
			"pass":        strconv.FormatBool(r.Pass),
		}
		if r.Error != "" {
			fields["error"] = r.Error
		}
		severity := "INFO"
		if !r.Pass {
			severity = "ERROR"
		}
		logJSON(severity, fields)
		if r.Pass {
			passed++
		} else {
			failed++
		}
	}

	logJSON("INFO", map[string]string{
		"event":  "summary",
		"total":  strconv.Itoa(len(results)),
		"passed": strconv.Itoa(passed),
		"failed": strconv.Itoa(failed),
	})

	if failed > 0 {
		os.Exit(1)
	}
}

func requireEnv(key string) string {
	val := os.Getenv(key)
	if val == "" {
		logJSON("ERROR", map[string]string{
			"event":   "missing_env",
			"message": fmt.Sprintf("required environment variable %s is not set", key),
		})
		os.Exit(1)
	}
	return val
}

func parseConcurrency(val string, defaultVal int) int {
	if val == "" {
		return defaultVal
	}
	n, err := strconv.Atoi(val)
	if err != nil || n < 1 {
		return defaultVal
	}
	return n
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

func listServices(ctx context.Context, projectID, region, prefix string) ([]serviceInfo, error) {
	client, err := run.NewServicesClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("creating services client: %w", err)
	}
	defer client.Close()

	parent := fmt.Sprintf("projects/%s/locations/%s", projectID, region)
	req := &runpb.ListServicesRequest{
		Parent: parent,
	}

	var services []serviceInfo
	it := client.ListServices(ctx, req)
	for {
		svc, err := it.Next()
		if err == iterator.Done {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("listing services: %w", err)
		}

		// Extract short name from full resource name
		// Format: projects/{project}/locations/{location}/services/{name}
		parts := strings.Split(svc.Name, "/")
		shortName := parts[len(parts)-1]

		if strings.HasPrefix(shortName, prefix) {
			services = append(services, serviceInfo{
				Name: shortName,
				URI:  svc.Uri,
			})
		}
	}
	return services, nil
}

func pingAll(services []serviceInfo, concurrency int) []result {
	results := make([]result, len(services))
	sem := make(chan struct{}, concurrency)
	var wg sync.WaitGroup

	for i, svc := range services {
		wg.Add(1)
		go func(idx int, s serviceInfo) {
			defer wg.Done()
			sem <- struct{}{}
			results[idx] = pingService(s)
			<-sem
		}(i, svc)
	}

	wg.Wait()
	return results
}

func pingService(svc serviceInfo) result {
	url := svc.URI + "/ping"
	client := &http.Client{Timeout: 10 * time.Second}

	resp, err := client.Get(url)
	if err != nil {
		return result{
			Service: svc.Name,
			URL:     url,
			Pass:    false,
			Error:   err.Error(),
		}
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return result{
			Service:    svc.Name,
			URL:        url,
			StatusCode: resp.StatusCode,
			Pass:       false,
			Error:      fmt.Sprintf("failed to read response body: %s", err),
		}
	}

	return result{
		Service:    svc.Name,
		URL:        url,
		StatusCode: resp.StatusCode,
		Body:       string(data),
		Pass:       resp.StatusCode == http.StatusOK,
	}
}
