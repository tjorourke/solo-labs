package main

import (
	"encoding/json"
	"os"
	"testing"
)

func TestProfileChangesTaxonomyWithoutCode(t *testing.T) {
	raw,err:=os.ReadFile("../config/support-routing.json");if err!=nil{t.Fatal(err)}
	p,err:=loadProfile(raw);if err!=nil{t.Fatal(err)}
	var e evaluation
	if err:=json.Unmarshal([]byte(`{"model":"jev-test","answers":{"department":{"type":"choice","choice":"technical","confidence":0.97,"probabilities":{"technical":0.98,"billing":0.01,"other":0.01}}},"usage":{"input_tokens":100,"output_tokens":20}}`),&e);err!=nil{t.Fatal(err)}
	d,err:=decide(e,p)
	if err!=nil || d.Task!="technical" || d.Profile!=p.Hash{t.Fatalf("%+v %v",d,err)}
	*p.MinConfidence=0.99
	d,err=decide(e,p)
	if err!=nil || d.Task!="other" || d.Status!="low_confidence"{t.Fatalf("%+v %v",d,err)}
}

func TestInvalidProfileCannotStart(t *testing.T) {
	for _, tt:=range []struct{name string;change func(map[string]any)}{
		{"missing threshold",func(p map[string]any){delete(p,"minConfidence")}},
		{"null threshold",func(p map[string]any){p["minMargin"]=nil}},
		{"threshold range",func(p map[string]any){p["minConfidence"]=1.1}},
		{"unknown question",func(p map[string]any){p["questionId"]="missing"}},
		{"unknown fallback",func(p map[string]any){p["fallback"]="external"}},
		{"unbounded timeout",func(p map[string]any){p["requestTimeoutMs"]=100000}},
		{"typo",func(p map[string]any){p["minConfidnce"]=0.2}},
		{"header injection",func(p map[string]any){q:=p["questions"].(map[string]any)["task"].(map[string]any);q["criteria"].(map[string]any)["bad\r\nheader"]="bad"}},
	} {t.Run(tt.name,func(t *testing.T){
		raw,err:=os.ReadFile("../config/task-routing.json");if err!=nil{t.Fatal(err)}
		var p map[string]any;if json.Unmarshal(raw,&p)!=nil{t.Fatal("invalid fixture")}
		tt.change(p);raw,_=json.Marshal(p)
		if _,err:=loadProfile(raw);err==nil{t.Fatal("accepted invalid profile")}
	})}
}
