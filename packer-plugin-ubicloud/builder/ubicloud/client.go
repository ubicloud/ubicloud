package ubicloud

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Client is a minimal Ubicloud API client for the Packer plugin.
type Client struct {
	APIURL    string
	APIToken  string
	ProjectID string
	Location  string
	HTTPHost  string // e.g. "api.localhost" for dev, "" for production
	http      *http.Client
}

func NewClient(apiURL, apiToken, projectID, location string) *Client {
	httpHost := ""
	// For dev environments using api.localhost
	if apiURL == "http://localhost:3000" || apiURL == "http://localhost:3000/" {
		httpHost = "api.localhost"
	}
	return &Client{
		APIURL:    apiURL,
		APIToken:  apiToken,
		ProjectID: projectID,
		Location:  location,
		HTTPHost:  httpHost,
		http:      &http.Client{Timeout: 30 * time.Second},
	}
}

func (c *Client) do(method, path string, body interface{}) ([]byte, int, error) {
	var bodyReader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, 0, fmt.Errorf("marshal body: %w", err)
		}
		bodyReader = bytes.NewReader(data)
	}

	req, err := http.NewRequest(method, c.APIURL+path, bodyReader)
	if err != nil {
		return nil, 0, fmt.Errorf("new request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.APIToken)
	req.Header.Set("Content-Type", "application/json")
	if c.HTTPHost != "" {
		req.Host = c.HTTPHost
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("http do: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, resp.StatusCode, fmt.Errorf("read body: %w", err)
	}

	return respBody, resp.StatusCode, nil
}

// VM represents a Ubicloud VM.
type VM struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	State      string `json:"state"`
	IP4        string `json:"ip4"`
	IP6        string `json:"ip6"`
	IP4Enabled bool   `json:"ip4_enabled"`
	UnixUser   string `json:"unix_user"`
}

// CreateVMRequest represents the request body for creating a VM.
type CreateVMRequest struct {
	PublicKey   string `json:"public_key"`
	Size        string `json:"size"`
	Arch        string `json:"arch,omitempty"`
	StorageSize int    `json:"storage_size,omitempty"`
	BootImage   string `json:"boot_image,omitempty"`
}

// CreateVM creates a temporary builder VM.
func (c *Client) CreateVM(name string, req CreateVMRequest) (*VM, error) {
	path := fmt.Sprintf("/project/%s/location/%s/vm/%s", c.ProjectID, c.Location, name)
	body, status, err := c.do("POST", path, req)
	if err != nil {
		return nil, err
	}
	if status != 200 {
		return nil, fmt.Errorf("create VM returned %d: %s", status, string(body))
	}
	var vm VM
	if err := json.Unmarshal(body, &vm); err != nil {
		return nil, fmt.Errorf("unmarshal VM: %w", err)
	}
	return &vm, nil
}

// GetVM returns the current state of a VM.
func (c *Client) GetVM(name string) (*VM, error) {
	path := fmt.Sprintf("/project/%s/location/%s/vm/%s", c.ProjectID, c.Location, name)
	body, status, err := c.do("GET", path, nil)
	if err != nil {
		return nil, err
	}
	if status != 200 {
		return nil, fmt.Errorf("get VM returned %d: %s", status, string(body))
	}
	var vm VM
	if err := json.Unmarshal(body, &vm); err != nil {
		return nil, fmt.Errorf("unmarshal VM: %w", err)
	}
	return &vm, nil
}

// StopVM stops a VM.
func (c *Client) StopVM(name string) error {
	path := fmt.Sprintf("/project/%s/location/%s/vm/%s/stop", c.ProjectID, c.Location, name)
	body, status, err := c.do("POST", path, nil)
	if err != nil {
		return err
	}
	if status != 200 {
		return fmt.Errorf("stop VM returned %d: %s", status, string(body))
	}
	return nil
}

// DeleteVM deletes a VM.
func (c *Client) DeleteVM(name string) error {
	path := fmt.Sprintf("/project/%s/location/%s/vm/%s", c.ProjectID, c.Location, name)
	body, status, err := c.do("DELETE", path, nil)
	if err != nil {
		return err
	}
	if status != 204 && status != 200 {
		return fmt.Errorf("delete VM returned %d: %s", status, string(body))
	}
	return nil
}

// MachineImage represents a Ubicloud machine image.
type MachineImage struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	State string `json:"state"`
}

// CreateMachineImageRequest represents the request body for creating a machine image.
type CreateMachineImageRequest struct {
	VMID        string `json:"vm_id"`
	Description string `json:"description,omitempty"`
}

// CreateMachineImage creates a machine image from a stopped VM.
func (c *Client) CreateMachineImage(name string, req CreateMachineImageRequest) (*MachineImage, error) {
	path := fmt.Sprintf("/project/%s/location/%s/machine-image/%s", c.ProjectID, c.Location, name)
	body, status, err := c.do("POST", path, req)
	if err != nil {
		return nil, err
	}
	if status != 200 {
		return nil, fmt.Errorf("create machine image returned %d: %s", status, string(body))
	}
	var mi MachineImage
	if err := json.Unmarshal(body, &mi); err != nil {
		return nil, fmt.Errorf("unmarshal machine image: %w", err)
	}
	return &mi, nil
}

// GetMachineImage returns the current state of a machine image.
func (c *Client) GetMachineImage(name string) (*MachineImage, error) {
	path := fmt.Sprintf("/project/%s/location/%s/machine-image/%s", c.ProjectID, c.Location, name)
	body, status, err := c.do("GET", path, nil)
	if err != nil {
		return nil, err
	}
	if status != 200 {
		return nil, fmt.Errorf("get machine image returned %d: %s", status, string(body))
	}
	var mi MachineImage
	if err := json.Unmarshal(body, &mi); err != nil {
		return nil, fmt.Errorf("unmarshal machine image: %w", err)
	}
	return &mi, nil
}

// DeleteMachineImage deletes a machine image.
func (c *Client) DeleteMachineImage(name string) error {
	path := fmt.Sprintf("/project/%s/location/%s/machine-image/%s", c.ProjectID, c.Location, name)
	body, status, err := c.do("DELETE", path, nil)
	if err != nil {
		return err
	}
	if status != 204 && status != 200 {
		return fmt.Errorf("delete machine image returned %d: %s", status, string(body))
	}
	return nil
}
