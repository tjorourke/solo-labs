package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"regexp"
)

type question struct {
	Type string `json:"type"`
	Instructions json.RawMessage `json:"instructions"`
	Criteria map[string]json.RawMessage `json:"criteria"`
}

// Loaded once before the gRPC listener starts. No task names or destinations
// are compiled into the adapter. A deployment selects a profile by mounted path.
type profile struct {
	Model string `json:"model"`
	QuestionID string `json:"questionId"`
	MinConfidence *float64 `json:"minConfidence"`
	MinMargin *float64 `json:"minMargin"`
	Fallback string `json:"fallback"`
	RequestTimeoutMs int `json:"requestTimeoutMs"`
	Questions map[string]question `json:"questions"`
	Hash string `json:"-"`
}

var labelPattern = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,62}$`)
var modelPattern = regexp.MustCompile(`^jev-[a-zA-Z0-9.-]+$`)

func loadProfile(raw []byte) (*profile,error) {
	if len(raw)>32768 { return nil,errors.New("profile_over_32_KiB") }
	var p profile
	d:=json.NewDecoder(bytes.NewReader(raw));d.DisallowUnknownFields()
	if d.Decode(&p)!=nil || d.Decode(new(any))!=io.EOF { return nil,errors.New("invalid_profile_json") }
	if !modelPattern.MatchString(p.Model) || p.MinConfidence==nil || p.MinMargin==nil || !bounded(*p.MinConfidence) || !bounded(*p.MinMargin) || p.RequestTimeoutMs<100 || p.RequestTimeoutMs>10000 || len(p.Questions)<1 || len(p.Questions)>16 {
		return nil,errors.New("invalid_profile_settings")
	}
	for id,q:=range p.Questions {
		if !labelPattern.MatchString(id) || q.Type!="choice" || len(q.Instructions)==0 || bytes.Equal(q.Instructions,[]byte("null")) || len(q.Criteria)<2 || len(q.Criteria)>255 { return nil,errors.New("invalid_choice_question") }
		for label:=range q.Criteria { if !labelPattern.MatchString(label) { return nil,errors.New("invalid_choice_label") } }
	}
	q,ok:=p.Questions[p.QuestionID]
	if !ok { return nil,errors.New("questionId_not_found") }
	if _,ok:=q.Criteria[p.Fallback];!ok { return nil,errors.New("fallback_not_in_selected_choices") }
	hash:=sha256.Sum256(raw);p.Hash=hex.EncodeToString(hash[:])[:12]
	return &p,nil
}
