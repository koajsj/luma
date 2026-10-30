// Offline witness recovery contract checker, not a witness or proof verifier.
// Nothing here signs, publishes, writes storage, or authorizes a Luma session.
package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
)

type checkpoint struct {
	Size string `json:"size"`
	Root string `json:"root"`
}

// record is a recovery projection, not the complete durable record. The witness
// must additionally retain exact proof/frontier/signing bytes and signed output.
type record struct {
	Version          int        `json:"version"`
	Config           string     `json:"config"`
	Witness          string     `json:"witness"`
	KeyEpoch         string     `json:"keyEpoch"`
	Generation       string     `json:"generation"`
	Previous         string     `json:"previous"`
	Decision         string     `json:"decision"`
	PreviousDecision string     `json:"previousDecision"`
	Phase            string     `json:"phase"`
	From             checkpoint `json:"from"`
	To               checkpoint `json:"to"`
}

type anchor struct {
	Status     string `json:"status"`
	Config     string `json:"config"`
	Witness    string `json:"witness"`
	KeyEpoch   string `json:"keyEpoch"`
	Generation string `json:"generation"`
	Decision   string `json:"decision"`
}

type input struct {
	Record *record `json:"record"`
	Anchor anchor  `json:"anchor"`
}

func counter(s string) (uint64, bool) {
	n, err := strconv.ParseUint(s, 10, 64)
	return n, err == nil && strconv.FormatUint(n, 10) == s
}

func digest(s string) bool {
	b, err := hex.DecodeString(s)
	return err == nil && len(b) == 32 && hex.EncodeToString(b) == s
}

// plan returns a REQUIRED next step, never permission to skip proof validation,
// signature verification, durable I/O, or a signing-service fencing check. Even
// a "published" record must be authenticated and replayed before audit resumes.
func plan(in input) (string, error) {
	refuse := func(reason string) (string, error) { return "halt", errors.New(reason) }
	if in.Anchor.Status != "ready" {
		return refuse("anchor_not_ready")
	}
	if in.Record == nil {
		return refuse("record_missing")
	}
	r, a := in.Record, in.Anchor
	if r.Version != 1 {
		return refuse("unsupported_record")
	}
	for _, value := range []string{r.Config, r.Witness, r.Decision, r.PreviousDecision, r.From.Root, r.To.Root,
		a.Config, a.Witness, a.Decision} {
		if !digest(value) {
			return refuse("invalid_digest")
		}
	}
	keyEpoch, validEpoch := counter(r.KeyEpoch)
	gen, validGen := counter(r.Generation)
	prev, validPrev := counter(r.Previous)
	ag, validAnchor := counter(a.Generation)
	from, validFrom := counter(r.From.Size)
	to, validTo := counter(r.To.Size)
	if !validEpoch || keyEpoch == 0 || !validGen || !validPrev || !validAnchor || !validFrom || !validTo ||
		gen == 0 || prev != gen-1 {
		return refuse("invalid_counter")
	}
	if r.Config != a.Config || r.Witness != a.Witness || r.KeyEpoch != a.KeyEpoch {
		return refuse("anchor_identity_mismatch")
	}
	if to < from || (to == from && r.From.Root != r.To.Root) {
		return refuse("checkpoint_rollback_or_fork")
	}
	if r.Phase != "prepared" && r.Phase != "signed" && r.Phase != "published" {
		return refuse("invalid_phase")
	}
	if r.Decision == r.PreviousDecision {
		return refuse("reused_decision")
	}
	if ag == prev && a.Decision == r.PreviousDecision {
		if r.Phase != "prepared" {
			return refuse("unanchored_signature")
		}
		return "reverify_then_reserve", nil
	}
	if ag != gen || a.Decision != r.Decision {
		return refuse("anchor_conflict_or_rollback")
	}
	switch r.Phase {
	case "prepared":
		return "reverify_then_fenced_sign_and_persist", nil
	case "signed":
		return "reverify_then_publish_exact", nil
	default:
		return "reverify_then_resume_audit", nil
	}
}

func run(r io.Reader, w io.Writer) error {
	// This CLI accepts a small public-state projection only, not proof blobs or keys.
	data, err := io.ReadAll(io.LimitReader(r, 16*1024+1))
	if err != nil || len(data) > 16*1024 {
		return errors.New("invalid_contract_input")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	var in input
	if err := d.Decode(&in); err != nil {
		return errors.New("invalid_contract_input")
	}
	var extra any
	if err := d.Decode(&extra); err != io.EOF {
		return errors.New("invalid_contract_input")
	}
	action, err := plan(in)
	if err != nil {
		return err
	}
	return json.NewEncoder(w).Encode(struct {
		NextStep string `json:"requiredNextStep"`
	}{action})
}

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		// Errors are fixed identifiers. Never echo input, proofs, or storage contents.
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
