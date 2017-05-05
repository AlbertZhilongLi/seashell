import * as React from "react";

import {merge} from "ramda";

import * as Blueprint from "@blueprintjs/core";
import {map, actionsInterface} from "../../../actions";
import {showError} from "../../../partials/Errors";

export interface AddFileProps {questions: string[]; closefunc: Function; };

/* Note that this class makes use of the built-in File class,
    so be careful if Seashell's File class needs to be used
    here in the future. */

class AddFile extends React.Component<AddFileProps&actionsInterface, { file: string, prevFile: string, uploadFiles: File[], fieldsDisabled: boolean}> {
  project: string;
  question: string;

  constructor(props: AddFileProps&actionsInterface) {
    super(props);
    if (this.props.appState.currentProject && this.props.appState.currentProject.currentQuestion) {
      this.project = this.props.appState.currentProject.id;
      this.question = this.props.appState.currentProject.currentQuestion.name;
      this.state = {
        file: "",
        prevFile: "",
        uploadFiles: [],
        fieldsDisabled: false
      };
    } else {
      throw new Error("AddFile invoke on undefined project!");
    }
  }

  private getDefaultContents(filename: string): string {
    const ext = filename.split(".").pop();
    switch (ext) {
      case "c":
        return "\nint main() {\n\treturn 0;\n}\n";
      case "h":
        return "\n// Write your interface here.\n";
      case "rkt":
        return "#lang racket\n\n";
      default:
        return "";
    }
  }

  private filesToArray(files: FileList|null): File[] {
    if (files === null) {
      return [];
    }
    let result = [];
    for (let i = 0; i < files.length; i++) {
      result.push(files[i]);
    }
    return result;
  }

  private submitForm() {
    this.setState(merge(this.state, {fieldsDisabled: true}));
    let proms: Promise<any>[] = [];
    if (this.state.file) {
      proms.push(this.props.dispatch.file.addFile(
        this.project,
        `${this.question}/${this.state.file}`,
        this.getDefaultContents(this.state.file)));
    }
    if (this.state.uploadFiles) {
      proms.concat(this.state.uploadFiles.map((file: File) => new Promise((resolve, reject) => {
        let reader = new FileReader();
        reader.onload = () => {
          this.props.dispatch.file.addFile(
              this.project, `${this.question}/${file.name}`, reader.result)
            .then(() => resolve())
            .catch(() => reject(file.name));
        };
        reader.onerror = () => {
          reject(file.name);
        };
        reader.readAsDataURL(file);
      })));
    }
    Promise.all(proms).then(() => this.props.closefunc())
      .catch(cause => showError(`Failed to upload file ${cause}.`))
      .then(() => this.setState(merge(this.state, {fieldsDisabled: false})));
  }

  render() {
    return(<div className="pt-dialog-body">
      <p>What would you like to call this file?</p>
      <div>
        <label>New File:
          <input className="pt-input pt-fill" required
            disabled={this.state.fieldsDisabled} type="text" value={this.state.file}
          onBlur={() => {
            if (this.state.file === "" || this.state.file.includes("/")) {
              this.setState(merge(this.state, {file: this.state.prevFile}));
            }
            else {
              this.setState(merge(this.state, {prevFile: this.state.file}));
            }
          }}
          onKeyPress={(e: any) => {
            if (e.key === "Enter") {
              this.submitForm();
            }
          }}
          onChange={(e => this.setState(merge(this.state, {file: e.currentTarget.value})))}/>
        </label><br />
        <label>Upload Files:
          <input type="file" multiple disabled={this.state.fieldsDisabled} onChange={
            (e => this.setState(merge(this.state, {
              uploadFiles: this.filesToArray(e.currentTarget.files)
            })))
          } />
        </label>
      </div>
      <div className="pt-button-group">
        <button type="button" className="pt-button" onClick={() => {
          this.props.closefunc();
        }}>Cancel</button>
        <button type="button" className="pt-button pt-intent-primary" disabled={
          (this.state.file === "" || this.state.file.includes("/")) && this.state.uploadFiles === []
        } onClick={() => this.submitForm()}>Add File</button>
      </div>
    </div>
    );
  }
}

export default map<AddFileProps>(AddFile);