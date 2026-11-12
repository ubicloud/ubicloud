package provider

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"slices"
)

// settle follows rule lifecycle: it reads the object at path while its
// lifecycle attribute holds a pending value, and returns the last body read.
// A failed value ends the wait with an error that names the value, and a 404
// ends it with an error too. A type without a lifecycle attribute is read
// once.
func (r *genericResource) settle(ctx context.Context, path string) (map[string]any, error) {
	var latest map[string]any
	err := r.poll(ctx, path, func(body map[string]any, err error) (bool, error) {
		if isNotFound(err) {
			return true, fmt.Errorf("%s disappeared", path)
		}
		if err != nil {
			return true, err
		}
		latest = body
		v := fmt.Sprint(body[r.t.life.attr])
		if slices.Contains(r.t.life.failed, v) {
			return true, fmt.Errorf("%s failed: its %s is %q", path, r.t.life.attr, v)
		}
		return !slices.Contains(r.t.life.pending, v), nil
	})
	return latest, err
}

// gone follows rule gone: it reads the object at path until the API answers
// 404, which a synchronous delete does at once.
func (r *genericResource) gone(ctx context.Context, path string) error {
	return r.poll(ctx, path, func(_ map[string]any, err error) (bool, error) {
		if isNotFound(err) {
			return true, nil
		}
		return err != nil, err
	})
}

// poll reads path until stop says to end or ctx's deadline passes. The wait
// between reads starts at the poll interval and doubles each time, up to six
// times the interval. A deadline error names the lifecycle value last seen.
func (r *genericResource) poll(ctx context.Context, path string, stop func(map[string]any, error) (bool, error)) error {
	interval, attr, last := r.c.poll, r.t.life.attr, ""
	for {
		body, err := r.c.do(ctx, request{method: http.MethodGet, path: path})
		if err == nil && attr != "" {
			last = fmt.Sprintf("; its %s was last %q", attr, fmt.Sprint(body[attr]))
		}
		done, err := stop(body, err)
		if !done && err == nil {
			err = sleep(ctx, interval)
		}
		if errors.Is(err, context.DeadlineExceeded) {
			return fmt.Errorf("timed out waiting on %s%s: %w", path, last, err)
		}
		if done || err != nil {
			return err
		}
		interval = min(2*interval, 6*r.c.poll)
	}
}
