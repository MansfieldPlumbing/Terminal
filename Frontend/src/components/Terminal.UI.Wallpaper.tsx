import React, { useEffect, useRef } from 'react';
import { makeStyles } from '@fluentui/react-components';

const vsSource = `
  attribute vec2 a_position;
  void main() {
    gl_Position = vec4(a_position, 0.0, 1.0);
  }
`;

const fsSource = `
  precision mediump float;
  uniform vec2 u_resolution;
  uniform float u_time;

  float random(vec2 st) { return fract(sin(dot(st.xy, vec2(12.9898,78.233))) * 43758.5453123); }
  float noise(vec2 st) {
      vec2 i = floor(st); vec2 f = fract(st);
      float a = random(i); float b = random(i + vec2(1.0, 0.0));
      float c = random(i + vec2(0.0, 1.0)); float d = random(i + vec2(1.0, 1.0));
      vec2 u = f * f * (3.0 - 2.0 * f);
      return mix(a, b, u.x) + (c - a)* u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
  }

  float fbm(vec2 st) {
      float v = 0.0; float a = 0.5;
      for (int i = 0; i < 4; ++i) {
          v += a * noise(st);
          st = st * 2.0;
          a *= 0.5;
      }
      return v;
  }

  void main() {
      vec2 st = gl_FragCoord.xy / u_resolution.xy;
      st.x *= u_resolution.x / u_resolution.y;
      vec3 color = mix(vec3(0.035, 0.26, 0.65), vec3(0.34, 0.63, 0.92), gl_FragCoord.y / u_resolution.y);
      vec2 cloudPos = st + vec2(u_time * 0.03, 0.0);
      float n = fbm(cloudPos * 3.0);
      n = smoothstep(0.4, 0.9, n);
      color = mix(color, vec3(1.0, 1.0, 1.0), n * 0.85);
      gl_FragColor = vec4(color, 1.0);
  }
`;

const useStyles = makeStyles({
  canvas: {
    position: 'absolute',
    inset: 0,
    width: '100%',
    height: '100%',
    zIndex: -10,
  },
});

export default function WebGLWallpaper() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const styles = useStyles();

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const gl = canvas.getContext('webgl', { alpha: false, antialias: false });
    if (!gl) return;

    const compile = (type: number, src: string) => {
      const s = gl.createShader(type)!;
      gl.shaderSource(s, src);
      gl.compileShader(s);
      return s;
    };

    const program = gl.createProgram()!;
    gl.attachShader(program, compile(gl.VERTEX_SHADER, vsSource));
    gl.attachShader(program, compile(gl.FRAGMENT_SHADER, fsSource));
    gl.linkProgram(program);
    gl.useProgram(program);

    const verts = new Float32Array([-1,-1,  1,-1,  -1,1,  -1,1,  1,-1,  1,1]);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, verts, gl.STATIC_DRAW);

    const posLoc = gl.getAttribLocation(program, 'a_position');
    gl.enableVertexAttribArray(posLoc);
    gl.vertexAttribPointer(posLoc, 2, gl.FLOAT, false, 0, 0);

    const resLoc = gl.getUniformLocation(program, 'u_resolution');
    const timeLoc = gl.getUniformLocation(program, 'u_time');

    let animationId: number;
    let lastDrawTime = 0;
    const fpsInterval = 1000 / 24;

    const render = (time: number) => {
      animationId = requestAnimationFrame(render);
      const elapsed = time - lastDrawTime;
      if (elapsed < fpsInterval) return;
      lastDrawTime = time - (elapsed % fpsInterval);
      if (canvas.width !== window.innerWidth || canvas.height !== window.innerHeight) {
        canvas.width = window.innerWidth;
        canvas.height = window.innerHeight;
        gl.viewport(0, 0, canvas.width, canvas.height);
        gl.uniform2f(resLoc, canvas.width, canvas.height);
      }
      gl.uniform1f(timeLoc, time * 0.001);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
    };

    animationId = requestAnimationFrame(render);
    return () => cancelAnimationFrame(animationId);
  }, []);

  return <canvas ref={canvasRef} className={styles.canvas} />;
}
