package action

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type Executor interface {
	Run(ctx context.Context, req RunRequest) (RunResult, error)
}

type RunRequest struct {
	Workdir   string
	Secrets   map[string]string
	Vars      map[string]string
	Env       map[string]string
	EventName string
	Output    io.Writer
}

type RunResult struct {
	Conclusion string
	Log        []byte
}

// writePythonShims creates a temp dir with pip->pip3 and python->python3
// wrappers for systems where only the versioned commands are on PATH.
// Returns the dir path; the caller is responsible for removing it.
func writePythonShims() (string, error) {
	dir, err := os.MkdirTemp("", "python-shim-*")
	if err != nil {
		return "", err
	}
	shims := map[string]string{
		"pip":    "#!/bin/sh\nexec pip3 \"$@\"\n",
		"python": "#!/bin/sh\nexec python3 \"$@\"\n",
	}
	for name, script := range shims {
		p := filepath.Join(dir, name)
		if writeErr := os.WriteFile(p, []byte(script), 0o755); writeErr != nil {
			os.RemoveAll(dir)
			return "", writeErr
		}
	}
	return dir, nil
}

// buildHostEnv builds the environment for act, starting from the current
// process env and patching common macOS issues that arise because act runs
// as a subprocess and may not inherit a full login-shell environment.
// The returned cleanup func must be called when the act process exits.
func buildHostEnv() ([]string, func()) {
	env := os.Environ()
	cleanup := func() {}

	// Python: if any unversioned command (pip, python) is missing but its
	// versioned counterpart exists, prepend shims for both so workflow steps work.
	_, pipMissing := exec.LookPath("pip")
	_, pythonMissing := exec.LookPath("python")
	_, pip3Exists := exec.LookPath("pip3")
	_, python3Exists := exec.LookPath("python3")
	needShims := (pipMissing != nil && pip3Exists == nil) || (pythonMissing != nil && python3Exists == nil)
	if needShims {
		if shimDir, shimErr := writePythonShims(); shimErr == nil {
			env = prependPath(env, shimDir)
			cleanup = func() { os.RemoveAll(shimDir) }
		}
	}

	return env, cleanup
}

func prependPath(env []string, dir string) []string {
	for i, e := range env {
		if after, ok := strings.CutPrefix(e, "PATH="); ok {
			env[i] = "PATH=" + dir + ":" + after
			return env
		}
	}
	return append(env, "PATH="+dir+":"+os.Getenv("PATH"))
}

type ActExecutor struct {
	Platform string
}

func NewActExecutor() *ActExecutor {
	return &ActExecutor{Platform: "ubuntu-latest=-self-hosted"}
}

func (e *ActExecutor) Run(ctx context.Context, req RunRequest) (RunResult, error) {
	args := []string{
		req.EventName,
		"-P", e.Platform,
		"--directory", req.Workdir,
	}
	for name, val := range req.Secrets {
		args = append(args, "--secret", fmt.Sprintf("%s=%s", name, val))
	}
	for name, val := range req.Vars {
		args = append(args, "--var", fmt.Sprintf("%s=%s", name, val))
	}
	for name, val := range req.Env {
		args = append(args, "--env", fmt.Sprintf("%s=%s", name, val))
	}

	cmd := exec.CommandContext(ctx, "act", args...)
	cmd.Dir = req.Workdir

	env, cleanupEnv := buildHostEnv()
	defer cleanupEnv()
	cmd.Env = env

	var buf bytes.Buffer
	out := req.Output
	if out == nil {
		out = &buf
	}
	cmd.Stdout = out
	cmd.Stderr = out

	conclusion := "success"
	if err := cmd.Run(); err != nil {
		conclusion = "failure"
		fmt.Fprintf(out, "\nact error: %v\n", err)
	}
	return RunResult{Conclusion: conclusion, Log: buf.Bytes()}, nil
}
