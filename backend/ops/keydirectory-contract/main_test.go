package main

import (
	"bytes"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// These shared, hand-specified outcomes exercise crash-recovery decisions only.
// They are deliberately NOT presented as successful transparency proof vectors.
func TestWitnessRecoveryContract(t *testing.T) {
	data, err := os.ReadFile("../../../Documentation/Protocol/Fixtures/key_directory_witness_recovery_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Version int             `json:"version"`
		Base    json.RawMessage `json:"base"`
		Cases   []struct {
			Name  string          `json:"name"`
			Patch json.RawMessage `json:"patch"`
			Next  string          `json:"next"`
			Error string          `json:"error"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil || fixture.Version != 1 || len(fixture.Cases) == 0 {
		t.Fatalf("invalid contract fixture: %v", err)
	}
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			var base, patch map[string]any
			if json.Unmarshal(fixture.Base, &base) != nil || json.Unmarshal(c.Patch, &patch) != nil {
				t.Fatal("invalid recovery projection")
			}
			merge(base, patch)
			data, err := json.Marshal(base)
			if err != nil {
				t.Fatal(err)
			}
			var out bytes.Buffer
			err = run(bytes.NewReader(data), &out)
			if c.Error != "" {
				if err == nil || err.Error() != c.Error || out.Len() != 0 {
					t.Fatalf("expected halt %s without output; got %v", c.Error, err)
				}
				return
			}
			var got struct {
				Next string `json:"requiredNextStep"`
			}
			if err != nil || json.Unmarshal(out.Bytes(), &got) != nil || got.Next != c.Next {
				t.Fatalf("expected required step %s; got %s (%v)", c.Next, got.Next, err)
			}
		})
	}
	// A truncated input must not become acceptable by hiding trailing content.
	for _, data := range []string{string(fixture.Base) + " {}", string(fixture.Base) + strings.Repeat(" ", 16*1024)} {
		var out bytes.Buffer
		if err := run(strings.NewReader(data), &out); err == nil || out.Len() != 0 {
			t.Fatal("accepted trailing or oversized contract input")
		}
	}
}

// RFC 7396 object merge; fixture patches are objects. JSON null removes a field.
func merge(target, patch map[string]any) {
	for key, value := range patch {
		if value == nil {
			delete(target, key)
		} else if fields, ok := value.(map[string]any); ok {
			child, ok := target[key].(map[string]any)
			if !ok {
				child = map[string]any{}
				target[key] = child
			}
			merge(child, fields)
		} else {
			target[key] = value
		}
	}
}
