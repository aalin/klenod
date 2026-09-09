import { mat4 } from "npm://gl-matrix";
import { createNoise4D } from "npm://simplex-noise";
import styles from "./NoiseSphere.css";

const SEGMENTS = 48;
const RINGS = 24;
const RADIUS = 1.15;
const WOBBLE = 0.3;

const VERTEX_SHADER = `#version 300 es
in vec3 position;
uniform mat4 projection;
uniform mat4 model;
out float depth;

void main() {
  vec4 world = model * vec4(position, 1.0);
  gl_Position = projection * world;
  depth = world.z;
}
`;

const FRAGMENT_SHADER = `#version 300 es
precision mediump float;
in float depth;
uniform vec3 tint;
out vec4 color;

void main() {
  float fade = clamp((depth + 1.6) / 2.8, 0.12, 1.0);
  color = vec4(tint * fade, fade);
}
`;

// A UV sphere kept as unit directions. Each frame every direction is scaled by
// its own noise-displaced radius to build the vertex positions.
function sphereDirections(): Float32Array {
  const directions = new Float32Array((RINGS + 1) * (SEGMENTS + 1) * 3);
  let offset = 0;

  for (let ring = 0; ring <= RINGS; ring++) {
    const phi = (ring / RINGS) * Math.PI;

    for (let segment = 0; segment <= SEGMENTS; segment++) {
      const theta = (segment / SEGMENTS) * Math.PI * 2;

      directions[offset++] = Math.sin(phi) * Math.cos(theta);
      directions[offset++] = Math.cos(phi);
      directions[offset++] = Math.sin(phi) * Math.sin(theta);
    }
  }

  return directions;
}

// Line segments along each ring and down each column, so the sphere draws with
// gl.LINES and needs no lighting or normals.
function wireframeIndices(): Uint16Array {
  const indices: number[] = [];
  const stride = SEGMENTS + 1;

  for (let ring = 0; ring <= RINGS; ring++) {
    for (let segment = 0; segment < SEGMENTS; segment++) {
      const current = ring * stride + segment;
      indices.push(current, current + 1);
      if (ring < RINGS) indices.push(current, current + stride);
    }
  }

  return new Uint16Array(indices);
}

function compile(gl: WebGL2RenderingContext, type: number, source: string): WebGLShader | null {
  const shader = gl.createShader(type);
  if (!shader) return null;

  gl.shaderSource(shader, source);
  gl.compileShader(shader);

  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    console.error(gl.getShaderInfoLog(shader));
    gl.deleteShader(shader);
    return null;
  }

  return shader;
}

function createProgram(gl: WebGL2RenderingContext): WebGLProgram | null {
  const vertex = compile(gl, gl.VERTEX_SHADER, VERTEX_SHADER);
  const fragment = compile(gl, gl.FRAGMENT_SHADER, FRAGMENT_SHADER);
  if (!vertex || !fragment) return null;

  const program = gl.createProgram();
  if (!program) return null;

  gl.attachShader(program, vertex);
  gl.attachShader(program, fragment);
  gl.linkProgram(program);

  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    console.error(gl.getProgramInfoLog(program));
    return null;
  }

  return program;
}

export default class NoiseSphereElement extends HTMLElement {
  #frame = 0;

  connectedCallback(): void {
    const root = this.shadowRoot || this.attachShadow({ mode: "open" });
    root.adoptedStyleSheets = [styles];

    const canvas = document.createElement("canvas");
    canvas.width = 480;
    canvas.height = 360;

    const gl = canvas.getContext("webgl2", { alpha: true, antialias: true });

    if (!gl) {
      root.replaceChildren(<p class="fallback">This demo needs WebGL 2.</p>);
      return;
    }

    root.replaceChildren(canvas);
    this.#start(gl, canvas);
  }

  disconnectedCallback(): void {
    if (this.#frame) cancelAnimationFrame(this.#frame);
    this.#frame = 0;
  }

  #start(gl: WebGL2RenderingContext, canvas: HTMLCanvasElement): void {
    const program = createProgram(gl);
    if (!program) return;

    const directions = sphereDirections();
    const indices = wireframeIndices();
    const positions = new Float32Array(directions.length);
    const noise = createNoise4D();

    const buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, positions.byteLength, gl.DYNAMIC_DRAW);

    const position = gl.getAttribLocation(program, "position");
    gl.enableVertexAttribArray(position);
    gl.vertexAttribPointer(position, 3, gl.FLOAT, false, 0, 0);

    const elements = gl.createBuffer();
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, elements);
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, indices, gl.STATIC_DRAW);

    // gl-matrix builds the camera and model matrices.
    const projection = mat4.create();
    mat4.perspective(projection, Math.PI / 4, canvas.width / canvas.height, 0.1, 100);
    mat4.translate(projection, projection, [0, 0, -4.2]);

    const model = mat4.create();

    gl.useProgram(program);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.uniform3f(gl.getUniformLocation(program, "tint"), 0.55, 0.85, 1.0);

    const projectionLocation = gl.getUniformLocation(program, "projection");
    const modelLocation = gl.getUniformLocation(program, "model");

    const draw = (time: number): void => {
      const seconds = time / 1000;

      // simplex-noise displaces every vertex along its own direction. The fourth
      // dimension is time, so the surface drifts instead of spinning rigidly.
      for (let offset = 0; offset < directions.length; offset += 3) {
        const x = directions[offset];
        const y = directions[offset + 1];
        const z = directions[offset + 2];
        const radius = RADIUS + noise(x, y, z, seconds * 0.25) * WOBBLE;

        positions[offset] = x * radius;
        positions[offset + 1] = y * radius;
        positions[offset + 2] = z * radius;
      }

      mat4.identity(model);
      mat4.rotateY(model, model, seconds * 0.35);
      mat4.rotateX(model, model, Math.sin(seconds * 0.2) * 0.4);

      gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
      gl.bufferSubData(gl.ARRAY_BUFFER, 0, positions);

      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.uniformMatrix4fv(projectionLocation, false, projection);
      gl.uniformMatrix4fv(modelLocation, false, model);
      gl.drawElements(gl.LINES, indices.length, gl.UNSIGNED_SHORT, 0);

      this.#frame = requestAnimationFrame(draw);
    };

    this.#frame = requestAnimationFrame(draw);
  }
}
