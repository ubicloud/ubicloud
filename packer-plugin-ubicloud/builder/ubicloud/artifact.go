package ubicloud

import "fmt"

// Artifact is the result of a Ubicloud Packer build — a machine image.
type Artifact struct {
	ImageID   string
	ImageName string
	Location  string
	ProjectID string
}

func (a *Artifact) BuilderId() string {
	return "ubicloud.builder"
}

func (a *Artifact) Files() []string {
	return nil
}

func (a *Artifact) Id() string {
	return a.ImageID
}

func (a *Artifact) String() string {
	return fmt.Sprintf("Machine image '%s' (ID: %s) in %s", a.ImageName, a.ImageID, a.Location)
}

func (a *Artifact) State(name string) interface{} {
	return nil
}

func (a *Artifact) Destroy() error {
	return nil
}
